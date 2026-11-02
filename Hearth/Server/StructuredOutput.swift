import Foundation
#if canImport(FoundationModels)
import FoundationModels

/// Turns an OpenAI `response_format` JSON Schema into a Foundation Models schema, so Apple
/// Intelligence answers through guided generation: the reply always parses, enums are respected,
/// and a string's `pattern` holds while the model writes.
///
/// Covers what clients actually send: objects, arrays (`minItems`/`maxItems`), strings
/// (`enum`, `pattern`), integers, numbers and booleans.
@available(macOS 26.0, *)
enum StructuredOutput {
    /// - Parameter patterns: Whether to turn `pattern` into a guide. Not every model version
    ///   supports regex guides, so callers retry without them.
    static func schema(from format: OpenAI.ChatRequest.ResponseFormat, patterns: Bool = true) throws -> GenerationSchema? {
        guard format.type == "json_schema", let json = format.jsonSchema?.schema else { return nil }
        // Nested @Generable types arrive as "$ref": "#/$defs/Name"; resolve them against the root.
        let definitions = json.object?["$defs"]?.object ?? json.object?["definitions"]?.object ?? [:]
        let root = dynamic(json, name: identifier(format.jsonSchema?.name ?? "Response"), patterns: patterns,
                           definitions: definitions)
        return try GenerationSchema(root: root, dependencies: [])
    }

    static func dynamic(_ value: JSONValue, name: String, patterns: Bool = true,
                        definitions: [String: JSONValue] = [:], depth: Int = 0) -> DynamicGenerationSchema {
        guard let node = value.object, depth < 16 else { return DynamicGenerationSchema(type: String.self) }
        if let reference = node["$ref"]?.string, let key = reference.split(separator: "/").last.map(String.init),
           let target = definitions[key] {
            return dynamic(target, name: identifier(key), patterns: patterns, definitions: definitions, depth: depth + 1)
        }
        func child(_ value: JSONValue, _ childName: String) -> DynamicGenerationSchema {
            dynamic(value, name: childName, patterns: patterns, definitions: definitions, depth: depth + 1)
        }
        let description = node["description"]?.string

        if let choices = node["enum"]?.array?.compactMap(\.string), !choices.isEmpty {
            return DynamicGenerationSchema(name: name, description: description, anyOf: choices)
        }

        switch node["type"]?.string ?? (node["properties"] != nil ? "object" : "string") {
        case "object":
            let properties = node["properties"]?.object ?? [:]
            let required = node["required"]?.array?.compactMap(\.string) ?? properties.keys.sorted()
            // A JSON object has no order, but generation order matters: a model writes a better
            // summary after the details. Foundation Models' own schemas say it in "x-order";
            // otherwise follow `required`, which is an array, then the rest by name.
            let declared = node["x-order"]?.array?.compactMap(\.string) ?? required
            let order = declared.filter { properties[$0] != nil }
                + properties.keys.filter { !declared.contains($0) }.sorted()
            let fields = order.map { key in
                let childSchema = properties[key] ?? .object([:])
                return DynamicGenerationSchema.Property(
                    name: key,
                    description: childSchema.object?["description"]?.string,
                    schema: child(childSchema, name + "_" + identifier(key)),
                    isOptional: !required.contains(key)
                )
            }
            return DynamicGenerationSchema(name: name, description: description, properties: fields)

        case "array":
            return DynamicGenerationSchema(
                arrayOf: child(node["items"] ?? .object([:]), name + "_item"),
                minimumElements: node["minItems"]?.int,
                maximumElements: node["maxItems"]?.int
            )
        case "integer":
            if let low = node["minimum"]?.int, let high = node["maximum"]?.int, low <= high {
                return DynamicGenerationSchema(type: Int.self, guides: [.range(low...high)])
            }
            return DynamicGenerationSchema(type: Int.self)
        case "number":
            if let low = node["minimum"]?.number, let high = node["maximum"]?.number, low <= high {
                return DynamicGenerationSchema(type: Double.self, guides: [.range(low...high)])
            }
            return DynamicGenerationSchema(type: Double.self)
        case "boolean":
            return DynamicGenerationSchema(type: Bool.self)
        default:
            if patterns, let pattern = node["pattern"]?.string, let regex = try? Regex(pattern) {
                return DynamicGenerationSchema(type: String.self, guides: [.pattern(regex)])
            }
            return DynamicGenerationSchema(type: String.self)
        }
    }

    static func identifier(_ text: String) -> String {
        let cleaned = text.map { $0.isLetter || $0.isNumber ? $0 : "_" }
        return cleaned.isEmpty ? "Value" : String(cleaned)
    }
}
#endif
