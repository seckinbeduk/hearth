import Foundation

/// The subset of the OpenAI Chat Completions API that Hearth speaks.
enum OpenAI {

    struct ChatRequest: Decodable, Sendable {
        struct Message: Decodable, Sendable {
            let role: String
            let content: String

            enum CodingKeys: String, CodingKey { case role, content }

            init(role: String, content: String) {
                self.role = role
                self.content = content
            }

            /// `content` may be a string, null, or an array of parts ([{type: "text", text: ...}]).
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                role = try c.decode(String.self, forKey: .role)
                if let text = try? c.decode(String.self, forKey: .content) {
                    content = text
                } else if let parts = try? c.decode([Part].self, forKey: .content) {
                    content = parts.compactMap(\.text).joined(separator: "\n")
                } else {
                    content = ""
                }
            }

            struct Part: Decodable, Sendable {
                let type: String?
                let text: String?
            }
        }

        struct StreamOptions: Decodable, Sendable {
            let includeUsage: Bool?
            enum CodingKeys: String, CodingKey { case includeUsage = "include_usage" }
        }

        let model: String?
        let messages: [Message]
        let stream: Bool?
        let temperature: Double?
        let topP: Double?
        let maxTokens: Int?
        let maxCompletionTokens: Int?
        let streamOptions: StreamOptions?
        let responseFormat: ResponseFormat?

        enum CodingKeys: String, CodingKey {
            case model, messages, stream, temperature
            case topP = "top_p"
            case maxTokens = "max_tokens"
            case maxCompletionTokens = "max_completion_tokens"
            case streamOptions = "stream_options"
            case responseFormat = "response_format"
        }

        var tokenLimit: Int? { maxCompletionTokens ?? maxTokens }

        /// `{"type": "json_schema", "json_schema": {"name": …, "schema": {…}}}` or `{"type": "json_object"}`.
        struct ResponseFormat: Decodable, Sendable {
            struct Schema: Decodable, Sendable {
                let name: String?
                let schema: JSONValue?
            }
            let type: String
            let jsonSchema: Schema?

            enum CodingKeys: String, CodingKey {
                case type
                case jsonSchema = "json_schema"
            }

            var wantsJSON: Bool { type == "json_schema" || type == "json_object" }

            /// For models that can't be constrained: the same request, in words.
            var instruction: String? {
                guard wantsJSON else { return nil }
                guard let schema = jsonSchema?.schema, let data = try? JSONEncoder().encode(schema),
                      let text = String(data: data, encoding: .utf8) else {
                    return "Reply with only a JSON object, no other text."
                }
                return "Reply with only a JSON object that matches this JSON Schema, no other text:\n" + text
            }
        }
    }

    struct Usage: Codable, Sendable {
        let promptTokens: Int
        let completionTokens: Int
        let totalTokens: Int

        init(prompt: Int, completion: Int) {
            promptTokens = prompt
            completionTokens = completion
            totalTokens = prompt + completion
        }

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case totalTokens = "total_tokens"
        }
    }

    struct ChatCompletion: Encodable, Sendable {
        struct Choice: Encodable, Sendable {
            struct Message: Encodable, Sendable {
                let role = "assistant"
                let content: String
                let reasoningContent: String?
                enum CodingKeys: String, CodingKey {
                    case role, content
                    case reasoningContent = "reasoning_content"
                }
            }
            let index = 0
            let message: Message
            let finishReason: String
            enum CodingKeys: String, CodingKey {
                case index, message
                case finishReason = "finish_reason"
            }
        }

        let id: String
        let object = "chat.completion"
        let created: Int
        let model: String
        let choices: [Choice]
        let usage: Usage
    }

    struct ChatChunk: Encodable, Sendable {
        struct Choice: Encodable, Sendable {
            struct Delta: Encodable, Sendable {
                var role: String?
                var content: String?
                var reasoningContent: String?
                enum CodingKeys: String, CodingKey {
                    case role, content
                    case reasoningContent = "reasoning_content"
                }
            }
            let index = 0
            let delta: Delta
            let finishReason: String?
            enum CodingKeys: String, CodingKey {
                case index, delta
                case finishReason = "finish_reason"
            }

            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(index, forKey: .index)
                try c.encode(delta, forKey: .delta)
                // OpenAI sends an explicit null until the last chunk.
                try c.encode(finishReason, forKey: .finishReason)
            }
        }

        let id: String
        let object = "chat.completion.chunk"
        let created: Int
        let model: String
        let choices: [Choice]
        var usage: Usage?
    }

    struct ModelList: Encodable, Sendable {
        struct Entry: Encodable, Sendable {
            let id: String
            let object = "model"
            let created: Int
            let ownedBy: String
            enum CodingKeys: String, CodingKey {
                case id, object, created
                case ownedBy = "owned_by"
            }
        }
        let object = "list"
        let data: [Entry]
    }
}

/// Any JSON value, for the parts of a request Hearth passes through, like a response schema.
indirect enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var string: String? { if case .string(let value) = self { value } else { nil } }
    var array: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
    var object: [String: JSONValue]? { if case .object(let value) = self { value } else { nil } }
    var int: Int? { if case .number(let value) = self { Int(value) } else { nil } }
}
