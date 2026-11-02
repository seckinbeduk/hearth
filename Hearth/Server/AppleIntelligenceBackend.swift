import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Serves Apple's on-device model (macOS 26+) behind the same OpenAI-compatible endpoint.
enum AppleIntelligenceBackend {
    static let modelID = "apple-intelligence"

    /// The on-device model has a ~4K token window; keep the prompt comfortably under it.
    private static let maxPromptCharacters = 10_000

    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    /// Loads the on-device model ahead of the first request so it answers without a cold start.
    @MainActor static func prewarm() {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), isAvailable {
            let session = LanguageModelSession()
            session.prewarm()
            warmSession = session
        }
        #endif
    }

    #if canImport(FoundationModels)
    /// Keeps the prewarmed session (and so the loaded model) alive.
    @MainActor private static var warmSessionStorage: AnyObject?
    @available(macOS 26.0, *)
    @MainActor private static var warmSession: LanguageModelSession? {
        get { warmSessionStorage as? LanguageModelSession }
        set { warmSessionStorage = newValue }
    }
    #endif

    /// Streams text deltas.
    static func stream(messages: [OpenAI.ChatRequest.Message], temperature: Double?,
                       maxTokens: Int?) -> AsyncThrowingStream<String, Error> {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return makeStream(messages: messages, temperature: temperature, maxTokens: maxTokens)
        }
        #endif
        return AsyncThrowingStream { $0.finish(throwing: Unavailable()) }
    }

    /// A whole answer that follows `format`'s JSON Schema, through guided generation.
    /// Returns nil when there's no schema to follow; the caller streams plain text instead.
    static func respondStructured(messages: [OpenAI.ChatRequest.Message], temperature: Double?, maxTokens: Int?,
                                  format: OpenAI.ChatRequest.ResponseFormat) async throws -> String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), let schema = try StructuredOutput.schema(from: format) {
            let (system, prompt) = split(messages)
            let options = GenerationOptions(temperature: temperature, maximumResponseTokens: maxTokens)
            func respond(_ schema: GenerationSchema) async throws -> String {
                let session = system.isEmpty ? LanguageModelSession() : LanguageModelSession(instructions: system)
                return try await session.respond(to: prompt, schema: schema, options: options).content.jsonString
            }
            do {
                return try await respond(schema)
            } catch let failure where "\(failure)".localizedCaseInsensitiveContains("unsupported") {
                // Some guides (regex patterns) aren't supported by every model version: drop them, keep the rest.
                guard let relaxed = try StructuredOutput.schema(from: format, patterns: false) else { throw failure }
                return try await respond(relaxed)
            }
        }
        #endif
        return nil
    }

    struct Unavailable: LocalizedError {
        var errorDescription: String? { "Apple Intelligence isn't available on this Mac right now." }
    }

    /// System messages become instructions; the rest is flattened into one prompt, newest turns kept.
    static func split(_ messages: [OpenAI.ChatRequest.Message]) -> (instructions: String, prompt: String) {
        let system = messages.filter { $0.role == "system" || $0.role == "developer" }
            .map(\.content).joined(separator: "\n\n")
        let turns = messages.filter { $0.role == "user" || $0.role == "assistant" }

        guard turns.count > 1 else {
            return (system, String((turns.last?.content ?? "").suffix(maxPromptCharacters)))
        }

        var lines: [String] = []
        var budget = maxPromptCharacters
        for turn in turns.dropLast().reversed() {
            let line = (turn.role == "user" ? "User: " : "Assistant: ") + turn.content
            guard line.count <= budget else { break }
            lines.insert(line, at: 0)
            budget -= line.count
        }
        let last = String((turns.last?.content ?? "").suffix(max(1_000, budget)))
        let prompt = (lines.isEmpty ? "" : "Conversation so far:\n" + lines.joined(separator: "\n") + "\n\n")
            + "Reply to the user's latest message:\n" + last
        return (system, prompt)
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static func makeStream(messages: [OpenAI.ChatRequest.Message], temperature: Double?,
                                   maxTokens: Int?) -> AsyncThrowingStream<String, Error> {
        let (system, prompt) = split(messages)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let session = system.isEmpty
                        ? LanguageModelSession()
                        : LanguageModelSession(instructions: system)
                    let options = GenerationOptions(temperature: temperature, maximumResponseTokens: maxTokens)
                    var previous = ""
                    for try await snapshot in session.streamResponse(to: prompt, options: options) {
                        let text = snapshot.content
                        if text.hasPrefix(previous) {
                            let delta = String(text.dropFirst(previous.count))
                            if !delta.isEmpty { continuation.yield(delta) }
                        }
                        previous = text
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    #endif
}
