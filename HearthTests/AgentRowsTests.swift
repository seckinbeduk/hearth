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
}
