import Testing
import Foundation
@testable import Hearth

@MainActor
struct AgentRowsTests {
    private struct Silent: AgentSummarizer {
        func summarize(_ input: AgentSummaryInput) async throws -> String { throw CancellationError() }
    }

    private func model() -> AgentsModel {
        let settings = AgentSettings(defaults: nil)
        settings.isEnabled = true
        return AgentsModel(settings: settings, summarizer: Silent())
    }

    private func event(_ kind: AgentEvent.Kind, _ session: String, cwd: String?, at time: Date) -> AgentEvent {
        AgentEvent(agent: .claudeCode, sessionID: session, kind: kind, time: time, cwd: cwd)
    }

    @Test func permissionComesFirstEvenWhenItsTheQuietestSession() {
        let model = model()
        let t0 = Date.now.addingTimeInterval(-60)
        model.apply(event(.promptSubmitted, "asking", cwd: "/p/asking", at: t0))
        model.apply(event(.permissionRequested, "asking", cwd: nil, at: t0))
        for i in 0..<7 {
            model.apply(event(.promptSubmitted, "busy\(i)", cwd: "/p/busy\(i)", at: t0.addingTimeInterval(Double(i + 1))))
        }
        let rows = model.rows(at: .now)
        #expect(rows.first?.name == "asking")
        #expect(rows.prefix(AgentsSection.maxRows).contains { $0.name == "asking" })
        // Same state: newest start first, stable while events come in.
        #expect(rows.dropFirst().first?.name == "busy6")
    }

    @Test func sameProjectIsNumbered() {
        let model = model()
        let t0 = Date.now.addingTimeInterval(-60)
        model.apply(event(.promptSubmitted, "a", cwd: "/Users/user/projects/nib", at: t0))
        model.apply(event(.promptSubmitted, "b", cwd: "/Users/user/other/nib", at: t0.addingTimeInterval(1)))
        model.apply(event(.promptSubmitted, "c", cwd: nil, at: t0.addingTimeInterval(2)))
        let names = Set(model.rows(at: .now).map(\.name))
        #expect(names == ["nib", "nib #2", "Claude Code"])
    }

    @Test func hookStatusWithoutAPort() {
        let connected = try! AgentInstaller.connect(nil, agent: .claudeCode, port: 8800, token: "t", path: "p")
        #expect(AgentInstaller.status(connected, agent: .claudeCode, port: nil, token: "t") == .connected)
        #expect(AgentInstaller.status(Data("{}".utf8), agent: .claudeCode, port: nil, token: "t") == .notConnected)
        // Nothing known yet: no call to action.
        #expect(!model().nothingConnected)
    }

    @Test func projectIsWhereTheSessionStarted() {
        let model = model()
        let t0 = Date.now.addingTimeInterval(-30)
        model.apply(event(.promptSubmitted, "s", cwd: "/Users/user/coding", at: t0))
        model.apply(event(.toolStarted, "s", cwd: "/Users/user/coding/Hearth", at: t0.addingTimeInterval(1)))
        #expect(model.rows(at: .now).first?.name == "coding → Hearth")
    }

    @Test func childAsksParentDoesntShowAPill() {
        let model = model()
        let t0 = Date.now.addingTimeInterval(-30)
        model.apply(event(.promptSubmitted, "s", cwd: "/p/app", at: t0))
        var start = event(.subagentStarted, "s", cwd: nil, at: t0)
        start.subagentID = "a1"; start.subagentType = "reviewer"
        model.apply(start)
        var ask = event(.permissionRequested, "s", cwd: nil, at: t0)
        ask.subagentID = "a1"; ask.subagentType = "reviewer"
        model.apply(ask)
        let row = model.rows(at: .now).first
        #expect(row?.state == .phase(.running))
        #expect(row?.children.first?.phase == .permission)
        #expect(model.summaries[row!.id] == "Reviewer wants permission")
        #expect(model.needsUser)                         // the badge still counts it
    }

    @Test func endedRowDropsThePermissionLine() {
        let model = model()
        let t0 = Date.now.addingTimeInterval(-30)
        model.apply(event(.promptSubmitted, "s", cwd: "/p/app", at: t0))
        var ask = event(.permissionRequested, "s", cwd: nil, at: t0)
        ask.toolName = "Bash"; ask.toolSummary = "git push"
        model.apply(ask)
        #expect(model.rows(at: .now).first?.line == "Wants to run git push")
        model.apply(event(.sessionEnded, "s", cwd: nil, at: t0.addingTimeInterval(1)))
        #expect(model.rows(at: .now).first?.line == "Session ended")
    }

    /// The recorded Codex CLI session through the model the panel reads: a finished turn stays as
    /// "your turn" (it isn't ended or hidden); only SessionEnd ends it.
    @Test func codexSessionStaysVisibleAfterItsTurn() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Agents/codex-cli-session.jsonl")
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        let model = model()
        let start = Date.now.addingTimeInterval(-200)
        var rowsAfter: [Int: AgentRow?] = [:]
        for (index, line) in lines.enumerated() {
            let object = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            let body = try JSONSerialization.data(withJSONObject: try #require(object["body"]))
            let time = start.addingTimeInterval(Double(try #require(object["t_ms"] as? Int)) / 1000)
            if let event = AgentEventDecoder.decode(body, agent: .codex, receivedAt: time) { model.apply(event) }
            rowsAfter[index + 1] = model.rows(at: time.addingTimeInterval(1)).first
        }
        #expect(rowsAfter[5]??.state == .phase(.yourTurn))          // first Stop
        #expect(rowsAfter[10]??.state == .phase(.yourTurn))         // Interrupt
        #expect(rowsAfter[20]??.state == .phase(.yourTurn))         // last Stop, before /quit
        #expect(rowsAfter[20]??.agent == .codex)
        #expect(rowsAfter[21]??.state == .phase(.ended))            // SessionEnd
    }

    @Test func oneConnectedAgentDoesntHideTheOther() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("hearth-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let settings = AgentSettings(defaults: nil)
        let model = AgentsModel(settings: settings, home: home, summarizer: Silent())
        #expect(model.unconnected.isEmpty)                         // unknown until read
        model.refreshHookStatus(port: 8800)
        #expect(model.nothingConnected)
        try model.connect(.claudeCode, port: 8800)
        #expect(!model.nothingConnected)
        #expect(model.unconnected == [.codex])
    }

    /// A live Codex session that went quiet after its turn stays "your turn" (no SessionEnd), turns
    /// "Quiet" after 30 minutes and leaves only after 2 hours; Codex's own SessionEnd (reason "other",
    /// sent when the thread has no client and is idle) ends it.
    @Test func quietCodexSessionStaysUntilItReallyEnds() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Agents/codex-cli-session.jsonl")
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        let model = model()
        let start = Date.now.addingTimeInterval(-60)
        var lastTime = start
        // Everything up to the last Stop; no SessionEnd.
        for line in lines.dropLast() {
            let object = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            let body = try JSONSerialization.data(withJSONObject: try #require(object["body"]))
            lastTime = start.addingTimeInterval(Double(try #require(object["t_ms"] as? Int)) / 1000)
            if let event = AgentEventDecoder.decode(body, agent: .codex, receivedAt: lastTime) { model.apply(event) }
        }
        #expect(model.rows(at: lastTime.addingTimeInterval(5 * 60)).first?.state == .phase(.yourTurn))
        #expect(model.rows(at: lastTime.addingTimeInterval(31 * 60)).first?.state == .stale)
        #expect(model.rows(at: lastTime.addingTimeInterval(119 * 60)).count == 1)
        #expect(model.rows(at: lastTime.addingTimeInterval(121 * 60)).isEmpty)

        let end = try #require(lines.last)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(end.utf8)) as? [String: Any])
        let body = try JSONSerialization.data(withJSONObject: try #require(object["body"]))
        let event = try #require(AgentEventDecoder.decode(body, agent: .codex, receivedAt: lastTime.addingTimeInterval(60)))
        #expect(event.reason == "other")
        model.apply(event)
        #expect(model.rows(at: lastTime.addingTimeInterval(61)).first?.state == .phase(.ended))
    }
}
