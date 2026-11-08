import Foundation

/// The Agents switch and the per-install token the hooks send. Read from any thread (UserDefaults is thread-safe).
final class AgentSettings: @unchecked Sendable {
    static let enabledKey = "hearth.agents.enabled"
    static let tokenKey = "hearth.agents.token"

    /// `nil` keeps everything in memory (tests), so nothing lands in ~/Library/Preferences.
    private let defaults: UserDefaults?
    private var memory: [String: Any] = [:]
    private let lock = NSLock()

    init(defaults: UserDefaults? = .standard) { self.defaults = defaults }

    /// Off until the user turns the Agents section on.
    var isEnabled: Bool {
        get { value(Self.enabledKey) as? Bool ?? false }
        set { store(newValue, Self.enabledKey) }
    }

    /// Random, made on first use, kept for the life of the install. It only guards a loopback port,
    /// so UserDefaults is enough (no Keychain).
    var token: String {
        lock.lock(); defer { lock.unlock() }
        if let token = unlockedValue(Self.tokenKey) as? String, token.count == 64 { return token }
        var generator = SystemRandomNumberGenerator()
        let token = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }.joined()
        unlockedStore(token, Self.tokenKey)
        return token
    }

    private func value(_ key: String) -> Any? {
        lock.lock(); defer { lock.unlock() }
        return unlockedValue(key)
    }

    private func store(_ value: Any, _ key: String) {
        lock.lock(); defer { lock.unlock() }
        unlockedStore(value, key)
    }

    private func unlockedValue(_ key: String) -> Any? { defaults.map { $0.object(forKey: key) } ?? memory[key] }

    private func unlockedStore(_ value: Any, _ key: String) {
        if let defaults { defaults.set(value, forKey: key) } else { memory[key] = value }
    }

    func accepts(_ candidate: String?) -> Bool {
        guard let candidate else { return false }
        return Self.constantTimeEquals(Array(candidate.utf8), Array(token.utf8))
    }

    static func constantTimeEquals(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for index in a.indices { difference |= a[index] ^ b[index] }
        return difference == 0
    }
}

/// `POST /agents/claude-code` and `POST /agents/codex`: where the agents' hooks report.
///
/// Every request gets `200` with an empty body at once, before anything is parsed, whatever it holds:
/// an agent must never wait on Hearth, and a body could be read as hook output. Then the request is
/// checked (Agents on, the token, no `Origin`, a known event) and the event handed to `deliver`;
/// anything else is dropped. Bodies hold prompts and tool input: never logged, never stored.
/// Not an OpenAI request, so it's not counted in "Who's using it".
struct AgentEndpoint: Sendable {
    let settings: AgentSettings
    /// Must not block: called on the server's task, after the response went out.
    let deliver: @Sendable (AgentEvent) -> Void

    static func handles(_ path: String) -> Bool { path.hasPrefix("/agents/") }

    func handle(_ request: HTTPRequest, _ responder: HTTPResponder) async {
        await responder.respond(status: 200, contentType: "text/plain", body: Data())
        if let event = accept(request, receivedAt: .now) { deliver(event) }
    }

    /// The event this request carries, or `nil` if it must be dropped.
    func accept(_ request: HTTPRequest, receivedAt time: Date) -> AgentEvent? {
        guard request.method == "POST",
              let agent = AgentKind.allCases.first(where: { $0.path == request.path }),
              settings.isEnabled,
              // Browsers always send Origin; hooks never do. Keeps web pages from faking sessions.
              request.header("Origin") == nil,
              settings.accepts(request.header("X-Hearth-Token"))
        else { return nil }
        return AgentEventDecoder.decode(request.body, agent: agent, receivedAt: time)
    }
}
