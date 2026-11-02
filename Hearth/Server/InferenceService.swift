import Foundation
import Observation
import MLXLMCommon

/// Answers the OpenAI-compatible API with the local MLX model or Apple Intelligence,
/// and reports every token to `UsageStats` so the menu bar can show it live.
@MainActor
@Observable
final class InferenceService {
    enum Status: Equatable {
        case stopped
        case running(port: Int)
        case failed(String)
    }

    static let defaultPort = 8800

    private(set) var status: Status = .stopped
    var isRunning: Bool { if case .running = status { true } else { false } }
    var port: Int? { if case .running(let port) = status { port } else { nil } }
    var baseURL: String { "http://localhost:\(port ?? Self.defaultPort)/v1" }

    private let models: LocalModelManager
    private let stats: UsageStats
    private var server: HTTPServer?

    /// MLX runs one generation at a time; others wait their turn.
    private var mlxBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(models: LocalModelManager, stats: UsageStats) {
        self.models = models
        self.stats = stats
    }

    // MARK: - Lifecycle

    func start() async {
        if isRunning { return }
        let server = HTTPServer { [weak self] request, responder in
            guard let self else { await responder.respondError(status: 503, message: "Hearth is shutting down."); return }
            await self.handle(request, responder)
        }
        do {
            let preferred = UserDefaults.standard.integer(forKey: "hearth.port")
            let port = try await server.start(preferredPort: preferred > 0 ? preferred : Self.defaultPort)
            self.server = server
            status = .running(port: port)
            AppleIntelligenceBackend.prewarm()
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func stop() {
        server?.stop()
        server = nil
        status = .stopped
    }

    // MARK: - Routing

    private func handle(_ request: HTTPRequest, _ responder: HTTPResponder) async {
        switch (request.method, request.path) {
        case ("GET", "/"), ("GET", "/health"), ("GET", "/v1"):
            await responder.respondJSON(Health(status: "ok", model: activeModelName, server: "Hearth", version: Self.version))
        case ("GET", "/v1/models"):
            await responder.respondJSON(modelList())
        case ("POST", "/v1/chat/completions"), ("POST", "/chat/completions"):
            await chatCompletions(request, responder)
        case (_, "/v1/chat/completions"), (_, "/v1/models"):
            await responder.respondError(status: 405, message: "Method not allowed.")
        default:
            await responder.respondError(status: 404,
                message: "Hearth serves /v1/models and /v1/chat/completions. Path not found: \(request.path)")
        }
    }

    private struct Health: Encodable {
        let status: String
        let model: String?
        let server: String
        /// Lets clients check for features: structured output (`response_format`) needs 0.2 or later.
        let version: String
    }

    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

    private var activeModelName: String? {
        models.state == .ready ? models.activeModel?.id : nil
    }

    private func modelList() -> OpenAI.ModelList {
        let now = Int(Date.now.timeIntervalSince1970)
        var entries: [OpenAI.ModelList.Entry] = []
        if let model = models.activeModel, models.state == .ready {
            entries.append(.init(id: model.id, created: now, ownedBy: "hearth"))
            entries.append(.init(id: model.slug, created: now, ownedBy: "hearth"))
            entries.append(.init(id: "hearth", created: now, ownedBy: "hearth"))
        }
        if AppleIntelligenceBackend.isAvailable {
            entries.append(.init(id: AppleIntelligenceBackend.modelID, created: now, ownedBy: "apple"))
        }
        return OpenAI.ModelList(data: entries)
    }

    // MARK: - Chat completions

    private enum Backend {
        case mlx(ModelContainer, CatalogModel)
        case appleIntelligence
    }

    private func resolveBackend(for requested: String?) -> Result<Backend, BackendError> {
        let wantsApple = requested.map { $0.lowercased().hasPrefix("apple") } ?? false
        if wantsApple {
            return AppleIntelligenceBackend.isAvailable
                ? .success(.appleIntelligence)
                : .failure(.init(status: 503, message: "Apple Intelligence isn't available on this Mac. Turn it on in System Settings, or use model \"hearth\"."))
        }
        // Any other name goes to the local model, so clients with a fixed model name still work.
        if let container = models.container, let model = models.activeModel, models.state == .ready {
            return .success(.mlx(container, model))
        }
        switch models.state {
        case .downloading(let progress):
            return .failure(.init(status: 503, message: "The model is still downloading (\(Int(progress * 100))%). Try again shortly."))
        case .loading:
            return .failure(.init(status: 503, message: "The model is loading into memory. Try again in a few seconds."))
        default:
            if AppleIntelligenceBackend.isAvailable { return .success(.appleIntelligence) }
            return .failure(.init(status: 503, message: "No model is running. Open Hearth from the menu bar to start one."))
        }
    }

    private struct BackendError: Error {
        let status: Int
        let message: String
    }

    private func chatCompletions(_ request: HTTPRequest, _ responder: HTTPResponder) async {
        let body: OpenAI.ChatRequest
        do {
            body = try JSONDecoder().decode(OpenAI.ChatRequest.self, from: request.body)
        } catch {
            await responder.respondError(status: 400, message: "Couldn't read the request body: \(error.localizedDescription)")
            return
        }
        guard body.messages.contains(where: { $0.role == "user" }) else {
            await responder.respondError(status: 400, message: "messages must include at least one user message.")
            return
        }

        let backend: Backend
        switch resolveBackend(for: body.model) {
        case .success(let b): backend = b
        case .failure(let error):
            await responder.respondError(status: error.status, message: error.message, type: "model_not_ready")
            return
        }

        let client = ClientIdentifier.name(userAgent: request.header("user-agent"), title: request.header("x-title"))
        let modelName: String
        switch backend {
        case .mlx(_, let model): modelName = model.id
        case .appleIntelligence: modelName = AppleIntelligenceBackend.modelID
        }

        let output = Output(responder: responder, model: modelName, streaming: body.stream ?? false,
                            includeUsage: body.streamOptions?.includeUsage ?? false)
        let recordID = stats.begin(client: client, model: modelName)

        switch backend {
        case .mlx(let container, let model):
            await acquireMLX()
            stats.markGenerating(recordID)
            defer { releaseMLX() }
            await generateMLX(body, container: container, model: model, output: output, client: client, recordID: recordID)
        case .appleIntelligence:
            stats.markGenerating(recordID)
            await generateApple(body, output: output, client: client, recordID: recordID)
        }
    }

    private func generateMLX(_ body: OpenAI.ChatRequest, container: ModelContainer, model: CatalogModel,
                             output: Output, client: String, recordID: UUID) async {
        var parameters = GenerateParameters()
        parameters.maxTokens = min(body.tokenLimit ?? 4_096, 16_384)
        // Qwen3's recommended non-thinking sampling; presence penalty curbs loops in 4-bit models.
        parameters.temperature = Float(body.temperature ?? 0.7)
        parameters.topP = Float(body.topP ?? 0.8)
        parameters.topK = 20
        parameters.minP = 0
        parameters.presencePenalty = 1.0
        parameters.presenceContextSize = 128

        // Local models can't be constrained to a schema; ask for it in the system message instead.
        var requestMessages = body.messages
        if let instruction = body.responseFormat?.instruction {
            if let index = requestMessages.firstIndex(where: { $0.role == "system" || $0.role == "developer" }) {
                let existing = requestMessages[index]
                requestMessages[index] = .init(role: existing.role, content: existing.content + "\n\n" + instruction)
            } else {
                requestMessages.insert(.init(role: "system", content: instruction), at: 0)
            }
        }
        let messages: [Chat.Message] = requestMessages.compactMap { message -> Chat.Message? in
            switch message.role {
            case "system", "developer": return Chat.Message.system(message.content)
            case "user": return Chat.Message.user(message.content)
            case "assistant": return Chat.Message.assistant(message.content)
            case "tool": return Chat.Message.tool(message.content)
            default: return nil
            }
        }

        let session = ChatSession(container, generateParameters: parameters,
                                  additionalContext: ["enable_thinking": false])
        var promptTokens = 0
        var promptSeconds: Double?
        var completionTokens = 0
        var chunks = 0
        var finish = "stop"

        do {
            try await output.begin()
            stream: for try await event in session.streamDetails(to: messages) {
                switch event {
                case .chunk(let text):
                    chunks += 1
                    stats.token(for: recordID, client: client)
                    try await output.content(text)
                case .info(let info):
                    promptTokens = info.promptTokenCount
                    promptSeconds = info.promptTime
                    completionTokens = info.generationTokenCount
                    stats.recordSpeed(info.tokensPerSecond, model: model.id)
                    if let limit = parameters.maxTokens, info.generationTokenCount >= limit { finish = "length" }
                default:
                    break
                }
                if Task.isCancelled { break stream }
            }
            try await output.end(finish: finish, usage: .init(prompt: promptTokens, completion: max(completionTokens, chunks)))
            stats.finish(recordID, promptTokens: promptTokens, completionTokens: completionTokens, status: .done,
                         promptSeconds: promptSeconds)
        } catch is ClientGone {
            // Client hung up mid-stream (user pressed stop). Leaving the loop cancels generation.
            stats.finish(recordID, promptTokens: promptTokens, completionTokens: completionTokens, status: .cancelled)
        } catch {
            await output.fail(error.localizedDescription)
            stats.finish(recordID, promptTokens: promptTokens, completionTokens: completionTokens,
                         status: .failed(error.localizedDescription))
        }
    }

    private func generateApple(_ body: OpenAI.ChatRequest, output: Output, client: String, recordID: UUID) async {
        let promptChars = body.messages.reduce(0) { $0 + $1.content.count }
        let promptTokens = promptChars / 4
        var completionChars = 0
        var firstDelta: Date?

        do {
            try await output.begin()
            if let format = body.responseFormat,
               let json = try await AppleIntelligenceBackend.respondStructured(
                   messages: body.messages, temperature: body.temperature, maxTokens: body.tokenLimit, format: format) {
                // Guided generation returns the whole object at once.
                completionChars = json.count
                stats.token(for: recordID, client: client, count: max(1, json.count / 4))
                try await output.content(json)
            } else {
                for try await delta in AppleIntelligenceBackend.stream(messages: body.messages,
                                                                       temperature: body.temperature,
                                                                       maxTokens: body.tokenLimit) {
                    if firstDelta == nil { firstDelta = .now }
                    completionChars += delta.count
                    // The on-device API doesn't expose token counts; ~4 characters per token.
                    stats.token(for: recordID, client: client, count: max(1, delta.count / 4))
                    try await output.content(delta)
                }
            }
            let completion = max(1, completionChars / 4)
            // Measure from the first token so the on-device model's warm-up doesn't count as slowness.
            if let firstDelta, completion > 2 {
                let elapsed = Date.now.timeIntervalSince(firstDelta)
                if elapsed > 0.2 { stats.recordSpeed(Double(completion) / elapsed, model: AppleIntelligenceBackend.modelID) }
            }
            try await output.end(finish: "stop", usage: .init(prompt: promptTokens, completion: completion))
            stats.finish(recordID, promptTokens: promptTokens, completionTokens: completion, status: .done)
        } catch is ClientGone {
            stats.finish(recordID, promptTokens: promptTokens, completionTokens: completionChars / 4, status: .cancelled)
        } catch {
            await output.fail(error.localizedDescription)
            stats.finish(recordID, promptTokens: promptTokens, completionTokens: completionChars / 4,
                         status: .failed(error.localizedDescription))
        }
    }

    // MARK: - MLX queue

    private func acquireMLX() async {
        if !mlxBusy { mlxBusy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func releaseMLX() {
        if waiters.isEmpty { mlxBusy = false } else { waiters.removeFirst().resume() }
    }
}

struct ClientGone: Error {}

/// Writes either a single JSON response or an SSE stream, so generators don't care which.
@MainActor
private final class Output {
    let responder: HTTPResponder
    let model: String
    let streaming: Bool
    let includeUsage: Bool
    let id = "chatcmpl-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24).lowercased()
    let created = Int(Date.now.timeIntervalSince1970)
    private var text = ""
    private var thinking = ""

    init(responder: HTTPResponder, model: String, streaming: Bool, includeUsage: Bool) {
        self.responder = responder
        self.model = model
        self.streaming = streaming
        self.includeUsage = includeUsage
    }

    func begin() async throws {
        guard streaming else { return }
        do {
            try await responder.startEventStream()
            try await responder.sendEvent(chunk(.init(role: "assistant", content: "")))
        } catch { throw ClientGone() }
    }

    func content(_ delta: String) async throws {
        text += delta
        guard streaming else { return }
        do { try await responder.sendEvent(chunk(.init(content: delta))) } catch { throw ClientGone() }
    }

    func reasoning(_ delta: String) async throws {
        thinking += delta
        guard streaming else { return }
        do { try await responder.sendEvent(chunk(.init(reasoningContent: delta))) } catch { throw ClientGone() }
    }

    func end(finish: String, usage: OpenAI.Usage) async throws {
        if streaming {
            do {
                try await responder.sendEvent(chunk(.init(), finish: finish))
                if includeUsage {
                    try await responder.sendEvent(OpenAI.ChatChunk(id: id, created: created, model: model,
                                                                   choices: [], usage: usage))
                }
                try await responder.sendDone()
            } catch { throw ClientGone() }
            responder.close()
        } else {
            let message = OpenAI.ChatCompletion.Choice.Message(content: text,
                                                               reasoningContent: thinking.isEmpty ? nil : thinking)
            await responder.respondJSON(OpenAI.ChatCompletion(
                id: id, created: created, model: model,
                choices: [.init(message: message, finishReason: finish)], usage: usage))
        }
    }

    func fail(_ message: String) async {
        if streaming {
            // Headers are already out; report the error in-band the way OpenAI does.
            try? await responder.sendEvent(OpenAIError(error: .init(message: message, type: "server_error")))
            responder.close()
        } else {
            await responder.respondError(status: 500, message: message, type: "server_error")
        }
    }

    private func chunk(_ delta: OpenAI.ChatChunk.Choice.Delta, finish: String? = nil) -> OpenAI.ChatChunk {
        OpenAI.ChatChunk(id: id, created: created, model: model,
                         choices: [.init(delta: delta, finishReason: finish)])
    }
}
