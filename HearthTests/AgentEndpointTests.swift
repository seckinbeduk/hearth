import Testing
import Foundation
@testable import Hearth

/// Events the endpoint delivered, collected across threads.
private final class Delivered: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [AgentEvent] = []

    func add(_ event: AgentEvent) { lock.lock(); events.append(event); lock.unlock() }
    var all: [AgentEvent] { lock.lock(); defer { lock.unlock() }; return events }

    /// Delivery happens right after the response is sent, so give it a moment.
    func waitForCount(_ count: Int) async -> [AgentEvent] {
        for _ in 0..<100 where all.count < count { try? await Task.sleep(for: .milliseconds(10)) }
        return all
    }
}

/// In-memory settings: nothing is written to ~/Library/Preferences.
private func settings(enabled: Bool = true) -> AgentSettings {
    let settings = AgentSettings(defaults: nil)
    settings.isEnabled = enabled
    return settings
}

private let stopBody = Data(#"{"session_id":"s1","hook_event_name":"Stop","cwd":"/tmp/demo"}"#.utf8)

private func request(path: String = "/agents/claude-code", method: String = "POST",
                     headers: [String: String], body: Data = stopBody) -> HTTPRequest {
    HTTPRequest(method: method, path: path,
                headers: Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) }), body: body)
}

struct AgentSettingsTests {
    @Test func tokenIsRandomStableAndHex() {
        let a = settings(), b = settings()
        #expect(a.token.count == 64)
        let isHex = a.token.allSatisfy { $0.isHexDigit }
        #expect(isHex)
        #expect(a.token == a.token)
        #expect(a.token != b.token)
        #expect(a.accepts(a.token))
        #expect(!a.accepts(b.token))
        #expect(!a.accepts(String(a.token.dropLast())))
        #expect(!a.accepts(nil))
    }

    @Test func constantTimeCompare() {
        #expect(AgentSettings.constantTimeEquals(Array("abc".utf8), Array("abc".utf8)))
        #expect(!AgentSettings.constantTimeEquals(Array("abc".utf8), Array("abd".utf8)))
        #expect(!AgentSettings.constantTimeEquals(Array("abc".utf8), Array("abcd".utf8)))
    }
}

struct AgentEndpointAcceptTests {
    @Test func acceptsAGoodRequest() throws {
        let s = settings()
        let endpoint = AgentEndpoint(settings: s) { _ in }
        let event = try #require(endpoint.accept(request(headers: ["X-Hearth-Token": s.token]), receivedAt: .now))
        #expect(event.agent == .claudeCode)
        #expect(event.kind == .turnEnded(backgroundTasks: []))
        let codex = endpoint.accept(request(path: "/agents/codex", headers: ["X-Hearth-Token": s.token]), receivedAt: .now)
        #expect(codex?.agent == .codex)
    }

    @Test func dropsEverythingElse() {
        let s = settings()
        let endpoint = AgentEndpoint(settings: s) { _ in }
        let token = ["X-Hearth-Token": s.token]
        #expect(endpoint.accept(request(headers: [:]), receivedAt: .now) == nil)                                   // no token
        #expect(endpoint.accept(request(headers: ["X-Hearth-Token": "wrong"]), receivedAt: .now) == nil)           // wrong token
        #expect(endpoint.accept(request(headers: token.merging(["Origin": "https://example.com"]) { a, _ in a }),
                                receivedAt: .now) == nil)                                                         // browser
        #expect(endpoint.accept(request(headers: token, body: Data("{not json".utf8)), receivedAt: .now) == nil)  // malformed
        #expect(endpoint.accept(request(method: "GET", headers: token), receivedAt: .now) == nil)
        #expect(endpoint.accept(request(path: "/agents/other", headers: token), receivedAt: .now) == nil)
        let off = settings(enabled: false)
        #expect(AgentEndpoint(settings: off) { _ in }
            .accept(request(headers: ["X-Hearth-Token": off.token]), receivedAt: .now) == nil)              // Agents off
    }

    @Test func modelIgnoresEventsWhileAgentsAreOff() async {
        let s = settings(enabled: false)
        let model = await AgentsModel(settings: s)
        let event = AgentEvent(agent: .claudeCode, sessionID: "s", kind: .promptSubmitted, time: .now)
        await model.apply(event)
        #expect(await model.store.sessions.isEmpty)
    }
}

/// Over a real loopback server, like the hooks' curl does it.
@Suite(.serialized)
struct AgentEndpointServerTests {
    private func withServer(_ settings: AgentSettings,
                            _ body: (Int, Delivered) async throws -> Void) async throws {
        let delivered = Delivered()
        let endpoint = AgentEndpoint(settings: settings) { delivered.add($0) }
        let server = HTTPServer { request, responder in
            if AgentEndpoint.handles(request.path) { await endpoint.handle(request, responder) }
            else { await responder.respondError(status: 404, message: "no") }
        }
        let port = try await server.start(preferredPort: 18_850)
        defer { server.stop() }
        try await body(port, delivered)
    }

    private func post(_ port: Int, headers: [String: String], body: Data) async throws -> (HTTPURLResponse, Data) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/agents/claude-code")!)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 5
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await URLSession.shared.data(for: request)
        return (try #require(response as? HTTPURLResponse), data)
    }

    @Test func everyRequestGetsAnEmpty200AndOnlyGoodOnesCount() async throws {
        let s = settings()
        try await withServer(s) { port, delivered in
            let cases: [([String: String], Data)] = [
                (["X-Hearth-Token": s.token], stopBody),                                      // good
                (["X-Hearth-Token": s.token], Data("{not json".utf8)),                        // malformed
                ([:], stopBody),                                                              // no token
                (["X-Hearth-Token": s.token, "Origin": "https://example.com"], stopBody),     // browser
            ]
            for (headers, body) in cases {
                let (response, data) = try await post(port, headers: headers, body: body)
                #expect(response.statusCode == 200)
                #expect(data.isEmpty)
                #expect(response.value(forHTTPHeaderField: "Content-Length") == "0")
            }
            let events = await delivered.waitForCount(1)
            try await Task.sleep(for: .milliseconds(100))
            #expect(events.count == 1)
            #expect(delivered.all.count == 1)
        }
    }

    @Test func twoMegabyteBodyIsAnsweredAtOnce() async throws {
        let s = settings()
        try await withServer(s) { port, delivered in
            let padding = String(repeating: "x", count: 2 * 1_048_576)
            let body = Data(#"{"session_id":"s1","hook_event_name":"UserPromptSubmit","prompt":"\#(padding)"}"#.utf8)
            let start = ContinuousClock.now
            let (response, data) = try await post(port, headers: ["X-Hearth-Token": s.token, "Expect": ""], body: body)
            #expect(ContinuousClock.now - start < .milliseconds(500))
            #expect(response.statusCode == 200)
            #expect(data.isEmpty)
            #expect(await delivered.waitForCount(1).first?.kind == .promptSubmitted)
        }
    }
}
