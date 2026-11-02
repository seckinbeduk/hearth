import SwiftUI

/// Renders Markdown in model replies at block level: headings, paragraphs/lists, code blocks,
/// tables, quotes and rules. Inline styles (bold, italic, `code`, links) go through AttributedString.
/// Half-streamed code blocks and tables still render cleanly.
struct MarkdownView: View {
    let text: String
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(MarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let content):
                    Text(Self.inline(content))
                        .font(level == 1 ? .title3.weight(.bold) : level == 2 ? .headline : .subheadline.weight(.semibold))
                        .padding(.top, 4)
                case .paragraph(let content):
                    Text(Self.inline(content))
                        .lineSpacing(3)
                case .code(let content):
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(content)
                            .font(.system(.callout, design: .monospaced))
                            .padding(12)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.06), in: .rect(cornerRadius: 8))
                case .table(let table):
                    MarkdownTableView(table: table)
                case .quote(let content):
                    Text(Self.inline(content))
                        .foregroundStyle(.secondary)
                        .lineSpacing(3)
                        .padding(.leading, 12)
                        .overlay(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(Color.primary.opacity(0.2))
                                .frame(width: 3)
                        }
                case .rule:
                    Divider().padding(.vertical, 2)
                case .math(let content):
                    Text(LaTeXText.plain(content))
                        .font(.system(.body, design: .serif))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 2)
                }
            }
        }
        .foregroundStyle(tint)
        .textSelection(.enabled)
    }

    nonisolated static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: bullets(LaTeXText.replacingInlineMath(in: text)),
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }

    /// Turns leading "- ", "* ", "+ " into • (nested: ◦); numbered lists stay as they are.
    nonisolated static func bullets(_ text: String) -> String {
        guard text.contains("- ") || text.contains("* ") || text.contains("+ ") else { return text }
        return text.components(separatedBy: "\n").map { (line: String) -> String in
            let indent = line.prefix { $0 == " " || $0 == "\t" }
            let rest = line.dropFirst(indent.count)
            guard rest.count > 2, let marker = rest.first, "-*+".contains(marker), rest.dropFirst().first == " "
            else { return line }
            let symbol = indent.count >= 2 ? "◦ " : "• "
            return String(indent) + symbol + String(rest.dropFirst(2))
        }.joined(separator: "\n")
    }
}

// MARK: - Tables

struct MarkdownTable: Equatable {
    enum ColumnAlignment: Equatable { case leading, center, trailing }

    var header: [String]
    var alignments: [ColumnAlignment]
    var rows: [[String]]

    var columnCount: Int { header.count }

    func cell(_ row: Int, _ column: Int) -> String {
        column < rows[row].count ? rows[row][column] : ""
    }
}

private struct MarkdownTableView: View {
    let table: MarkdownTable

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(0..<table.columnCount, id: \.self) { column in
                        cell(table.header[column], column: column)
                            .fontWeight(.semibold)
                            .background(Color.primary.opacity(0.07))
                    }
                }
                ForEach(table.rows.indices, id: \.self) { row in
                    Divider().gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        ForEach(0..<table.columnCount, id: \.self) { column in
                            cell(table.cell(row, column), column: column)
                                .background(row.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.025))
                        }
                    }
                }
            }
        .clipShape(.rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
    }

    private func cell(_ text: String, column: Int) -> some View {
        let alignment = column < table.alignments.count ? table.alignments[column] : .leading
        let frameAlignment: Alignment = alignment == .trailing ? .trailing : alignment == .center ? .center : .leading
        return Text(MarkdownView.inline(text))
            .font(.callout)
            .multilineTextAlignment(alignment == .trailing ? .trailing : alignment == .center ? .center : .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: frameAlignment)
    }
}

// MARK: - Parsing

enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case code(String)
    case table(MarkdownTable)
    case quote(String)
    case rule
    /// LaTeX between \[ … \] or $$ … $$ (shown as plain text)
    case math(String)

    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var quote: [String] = []
        var code: [String]?
        var math: (lines: [String], close: String)?
        let lines = text.components(separatedBy: "\n")

        func flushParagraph() {
            let joined = paragraph.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !joined.trimmingCharacters(in: .whitespaces).isEmpty { blocks.append(.paragraph(joined)) }
            paragraph = []
        }
        func flushQuote() {
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))) }
            quote = []
        }
        func flushAll() {
            flushParagraph()
            flushQuote()
        }

        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            defer { index += 1 }

            if trimmed.hasPrefix("```") {
                if let open = code {
                    blocks.append(.code(open.joined(separator: "\n")))
                    code = nil
                } else {
                    flushAll()
                    code = []
                }
                continue
            }
            if code != nil {
                code?.append(line)
                continue
            }

            // Math block: \[ … \] or $$ … $$ (one line or spanning several)
            if let open = math {
                if let end = trimmed.range(of: open.close) {
                    blocks.append(.math((open.lines + [String(trimmed[..<end.lowerBound])])
                        .joined(separator: " ").trimmingCharacters(in: .whitespaces)))
                    math = nil
                } else {
                    math?.lines.append(trimmed)
                }
                continue
            }
            if let marks = [("\\[", "\\]"), ("$$", "$$")].first(where: { trimmed.hasPrefix($0.0) }) {
                let (openMark, closeMark) = marks
                flushAll()
                let rest = String(trimmed.dropFirst(openMark.count))
                if let end = rest.range(of: closeMark) {
                    blocks.append(.math(String(rest[..<end.lowerBound])))
                } else {
                    math = (rest.isEmpty ? [] : [rest], closeMark)
                }
                continue
            }

            // Table: header row followed by a separator row (|---|:--:|)
            if trimmed.contains("|"), index + 1 < lines.count,
               let alignments = separatorAlignments(lines[index + 1]) {
                let header = cells(trimmed)
                if header.count == alignments.count {
                    flushAll()
                    var rows: [[String]] = []
                    var next = index + 2
                    while next < lines.count {
                        let rowLine = lines[next].trimmingCharacters(in: .whitespaces)
                        guard rowLine.contains("|") else { break }
                        rows.append(cells(rowLine))
                        next += 1
                    }
                    blocks.append(.table(MarkdownTable(header: header, alignments: alignments, rows: rows)))
                    index = next - 1   // defer adds one
                    continue
                }
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }
            flushQuote()

            if trimmed.isEmpty {
                flushParagraph()
            } else if let heading = heading(trimmed) {
                flushParagraph()
                blocks.append(heading)
            } else if isRule(trimmed) {
                flushParagraph()
                blocks.append(.rule)
            } else {
                paragraph.append(line)
            }
        }

        if let open = code { blocks.append(.code(open.joined(separator: "\n"))) }
        if let open = math { blocks.append(.math(open.lines.joined(separator: " "))) }
        flushAll()
        return blocks
    }

    private static func heading(_ line: String) -> MarkdownBlock? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        return .heading(level: hashes, text: rest.trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    /// "| a | b |" → ["a", "b"]; an escaped \| stays inside the cell.
    static func cells(_ line: String) -> [String] {
        var row = line.trimmingCharacters(in: .whitespaces)
        if row.hasPrefix("|") { row.removeFirst() }
        if row.hasSuffix("|") && !row.hasSuffix("\\|") { row.removeLast() }

        var result: [String] = []
        var current = ""
        var escaped = false
        for character in row {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                result.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        result.append(current.trimmingCharacters(in: .whitespaces))
        return result
    }

    /// For a separator row, returns the column alignments: "|:---|:-:|--:|"
    static func separatorAlignments(_ line: String) -> [MarkdownTable.ColumnAlignment]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-"), trimmed.contains("|") else { return nil }
        let parts = cells(trimmed)
        guard !parts.isEmpty else { return nil }
        var alignments: [MarkdownTable.ColumnAlignment] = []
        for part in parts {
            let p = part.replacingOccurrences(of: " ", with: "")
            guard !p.isEmpty, p.contains("-"), p.allSatisfy({ $0 == "-" || $0 == ":" }) else { return nil }
            let left = p.hasPrefix(":"), right = p.hasSuffix(":")
            alignments.append(left && right ? .center : right ? .trailing : .leading)
        }
        return alignments
    }
}
