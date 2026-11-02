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
        let root = dynamic(json, name: identifier(format.jsonSchema?.name ?? "Response"), patterns: patterns)
        return try GenerationSchema(root: root, dependencies: [])
    }

    static func dynamic(_ value: JSONValue, name: String, patterns: Bool = true) -> DynamicGenerationSchema {
        guard let node = value.object else { return DynamicGenerationSchema(type: String.self) }
        let description = node["description"]?.string

        if let choices = node["enum"]?.array?.compactMap(\.string), !choices.isEmpty {
            return DynamicGenerationSchema(name: name, description: description, anyOf: choices)
        }

        switch node["type"]?.string ?? (node["properties"] != nil ? "object" : "string") {
        case "object":
            let properties = node["properties"]?.object ?? [:]
            let required = node["required"]?.array?.compactMap(\.string) ?? properties.keys.sorted()
            // A JSON object has no order, but generation order matters: a model writes a better
            // summary after the details. Follow `required`, which is an array, then the rest by name.
            let order = required.filter { properties[$0] != nil }
                + properties.keys.filter { !required.contains($0) }.sorted()
            let fields = order.map { key in
                let child = properties[key] ?? .object([:])
                return DynamicGenerationSchema.Property(
                    name: key,
                    description: child.object?["description"]?.string,
                    schema: dynamic(child, name: name + "_" + identifier(key), patterns: patterns),
                    isOptional: !required.contains(key)
                )
            }
            return DynamicGenerationSchema(name: name, description: description, properties: fields)

        case "array":
            return DynamicGenerationSchema(
                arrayOf: dynamic(node["items"] ?? .object([:]), name: name + "_item", patterns: patterns),
                minimumElements: node["minItems"]?.int,
                maximumElements: node["maxItems"]?.int
            )
        case "integer":
            return DynamicGenerationSchema(type: Int.self)
        case "number":
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
