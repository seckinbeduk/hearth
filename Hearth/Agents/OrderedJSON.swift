import Foundation

/// A JSON value that keeps object key order and number text, so Hearth can edit an agent's settings file
/// and leave everything it didn't touch as it was. Printed like `JSON.stringify(value, null, 2)`,
/// the format Claude Code itself writes.
indirect enum OrderedJSON: Equatable, Sendable {
    case object([(key: String, value: OrderedJSON)])
    case array([OrderedJSON])
    case string(String)
    /// The number exactly as written.
    case number(String)
    case bool(Bool)
    case null

    struct ParseError: Error, Equatable {
        let offset: Int
    }

    // MARK: - Access

    subscript(key: String) -> OrderedJSON? {
        guard case .object(let pairs) = self else { return nil }
        return pairs.last { $0.key == key }?.value
    }

    /// Sets `key` in an object, in place if it exists, else at the end.
    mutating func set(_ key: String, _ value: OrderedJSON?) {
        guard case .object(var pairs) = self else { return }
        if let index = pairs.lastIndex(where: { $0.key == key }) {
            if let value { pairs[index].value = value } else { pairs.remove(at: index) }
        } else if let value {
            pairs.append((key, value))
        }
        self = .object(pairs)
    }

    var objectPairs: [(key: String, value: OrderedJSON)]? {
        if case .object(let pairs) = self { pairs } else { nil }
    }

    var arrayValue: [OrderedJSON]? {
        if case .array(let items) = self { items } else { nil }
    }

    var stringValue: String? {
        if case .string(let text) = self { text } else { nil }
    }

    static func == (lhs: OrderedJSON, rhs: OrderedJSON) -> Bool {
        switch (lhs, rhs) {
        case (.object(let a), .object(let b)):
            a.count == b.count && zip(a, b).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        case (.array(let a), .array(let b)): a == b
        case (.string(let a), .string(let b)): a == b
        case (.number(let a), .number(let b)): a == b
        case (.bool(let a), .bool(let b)): a == b
        case (.null, .null): true
        default: false
        }
    }

    // MARK: - Parsing

    static func parse(_ data: Data) throws -> OrderedJSON {
        var parser = Parser(bytes: Array(data))
        parser.skipWhitespace()
        let value = try parser.value(depth: 0)
        parser.skipWhitespace()
        guard parser.index == parser.bytes.count else { throw ParseError(offset: parser.index) }
        return value
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x0A, 0x0D, 0x09].contains(bytes[index]) { index += 1 }
        }

        mutating func value(depth: Int) throws -> OrderedJSON {
            guard depth < 256, index < bytes.count else { throw ParseError(offset: index) }
            switch bytes[index] {
            case UInt8(ascii: "{"): return try object(depth: depth)
            case UInt8(ascii: "["): return try array(depth: depth)
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): try literal("true"); return .bool(true)
            case UInt8(ascii: "f"): try literal("false"); return .bool(false)
            case UInt8(ascii: "n"): try literal("null"); return .null
            default: return .number(try number())
            }
        }

        mutating func object(depth: Int) throws -> OrderedJSON {
            index += 1
            var pairs: [(key: String, value: OrderedJSON)] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1; return .object(pairs) }
            while true {
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw ParseError(offset: index) }
                let key = try string()
                skipWhitespace()
                try expect(":")
                skipWhitespace()
                pairs.append((key, try value(depth: depth + 1)))
                skipWhitespace()
                guard index < bytes.count else { throw ParseError(offset: index) }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                try expect("}")
                return .object(pairs)
            }
        }

        mutating func array(depth: Int) throws -> OrderedJSON {
            index += 1
            var items: [OrderedJSON] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
            while true {
                skipWhitespace()
                items.append(try value(depth: depth + 1))
                skipWhitespace()
                guard index < bytes.count else { throw ParseError(offset: index) }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                try expect("]")
                return .array(items)
            }
        }

        mutating func string() throws -> String {
            index += 1
            var out: [UInt8] = []
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                switch byte {
                case UInt8(ascii: "\""):
                    guard let text = String(bytes: out, encoding: .utf8) else { throw ParseError(offset: index) }
                    return text
                case UInt8(ascii: "\\"):
                    guard index < bytes.count else { throw ParseError(offset: index) }
                    let escape = bytes[index]
                    index += 1
                    switch escape {
                    case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): out.append(escape)
                    case UInt8(ascii: "b"): out.append(0x08)
                    case UInt8(ascii: "f"): out.append(0x0C)
                    case UInt8(ascii: "n"): out.append(0x0A)
                    case UInt8(ascii: "r"): out.append(0x0D)
                    case UInt8(ascii: "t"): out.append(0x09)
                    case UInt8(ascii: "u"):
                        var scalar = try hex4()
                        if (0xD800..<0xDC00).contains(scalar) {
                            guard index + 1 < bytes.count, bytes[index] == UInt8(ascii: "\\"),
                                  bytes[index + 1] == UInt8(ascii: "u") else { throw ParseError(offset: index) }
                            index += 2
                            let low = try hex4()
                            guard (0xDC00..<0xE000).contains(low) else { throw ParseError(offset: index) }
                            scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                        }
                        guard let unicode = Unicode.Scalar(scalar) else { throw ParseError(offset: index) }
                        out.append(contentsOf: Array(String(Character(unicode)).utf8))
                    default: throw ParseError(offset: index)
                    }
                default:
                    guard byte >= 0x20 else { throw ParseError(offset: index) }
                    out.append(byte)
                }
            }
            throw ParseError(offset: index)
        }

        mutating func hex4() throws -> UInt32 {
            guard index + 4 <= bytes.count,
                  let text = String(bytes: bytes[index..<index + 4], encoding: .ascii),
                  let value = UInt32(text, radix: 16) else { throw ParseError(offset: index) }
            index += 4
            return value
        }

        mutating func number() throws -> String {
            let start = index
            while index < bytes.count, "+-0123456789.eE".utf8.contains(bytes[index]) { index += 1 }
            // JSON's own grammar, stricter than Double(): no "+1", "01", ".5" or "1.".
            guard index > start, let text = String(bytes: bytes[start..<index], encoding: .ascii),
                  text.wholeMatch(of: /-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?/) != nil
            else { throw ParseError(offset: start) }
            return text
        }

        mutating func literal(_ word: String) throws {
            let expected = Array(word.utf8)
            guard index + expected.count <= bytes.count, Array(bytes[index..<index + expected.count]) == expected
            else { throw ParseError(offset: index) }
            index += expected.count
        }

        mutating func expect(_ character: Character) throws {
            guard index < bytes.count, bytes[index] == character.asciiValue else { throw ParseError(offset: index) }
            index += 1
        }
    }

    // MARK: - Printing

    /// Two-space indentation, `"key": value`, empty containers as `{}` / `[]`.
    func printed() -> String {
        var out = ""
        write(to: &out, indent: 0)
        return out
    }

    private func write(to out: inout String, indent: Int) {
        let pad = String(repeating: " ", count: indent + 2)
        let closing = String(repeating: " ", count: indent)
        switch self {
        case .object(let pairs):
            if pairs.isEmpty { out += "{}"; return }
            out += "{\n"
            for (offset, pair) in pairs.enumerated() {
                out += pad + Self.quoted(pair.key) + ": "
                pair.value.write(to: &out, indent: indent + 2)
                out += offset < pairs.count - 1 ? ",\n" : "\n"
            }
            out += closing + "}"
        case .array(let items):
            if items.isEmpty { out += "[]"; return }
            out += "[\n"
            for (offset, item) in items.enumerated() {
                out += pad
                item.write(to: &out, indent: indent + 2)
                out += offset < items.count - 1 ? ",\n" : "\n"
            }
            out += closing + "]"
        case .string(let text): out += Self.quoted(text)
        case .number(let text): out += text
        case .bool(let value): out += value ? "true" : "false"
        case .null: out += "null"
        }
    }

    static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}
