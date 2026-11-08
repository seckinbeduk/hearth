import Testing
import Foundation
@testable import Hearth

/// Recorded hook events (Step 0), redacted. Each line: `{"t_ms": …, "path": "/agents/<agent>", "body": {…}}`.
private struct Fixture {
    struct Line {
        var agent: AgentKind
        var time: Date
        var body: Data
    }

    static let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let lines: [Line]

    init(_ name: String) throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Agents/\(name).jsonl")
        let text = try String(contentsOf: url, encoding: .utf8)
        lines = try text.split(separator: "\n").map { raw in
            let object = try #require(try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
            let path = try #require(object["path"] as? String)
            let agent = try #require(AgentKind.allCases.first { $0.path == path })
            let ms = try #require(object["t_ms"] as? Int)
            let body = try JSONSerialization.data(withJSONObject: try #require(object["body"]))
            return Line(agent: agent, time: Self.start.addingTimeInterval(Double(ms) / 1000), body: body)
        }
    }

    /// Replays lines 1...`count` (1-based, as in the fixture file) into a fresh store.
    func replay(through count: Int? = nil) -> AgentSessionStore {
        var store = AgentSessionStore()
        for line in lines.prefix(count ?? lines.count) {
            if let event = AgentEventDecoder.decode(line.body, agent: line.agent, receivedAt: line.time) {
                store.apply(event)
            }
        }
        return store
    }

    func time(ofLine number: Int) -> Date { lines[number - 1].time }
}

private func only(_ store: AgentSessionStore) throws -> AgentSession {
    try #require(store.sessions.count == 1)
    return try #require(store.sessions.values.first)
}

struct AgentSessionReplayTests {
    // claude-code-session-subagent: auto mode, a background reviewer, six turns, /exit.

    @Test func firstTurnEndsAsYourTurn() throws {
        let fixture = try Fixture("claude-code-session-subagent")
        #expect(try only(fixture.replay(through: 1)).phase == .idle)
        #expect(try only(fixture.replay(through: 2)).phase == .running)
        let afterStop = try only(fixture.replay(through: 7))
        #expect(afterStop.phase == .yourTurn)
        #expect(afterStop.phaseSince == fixture.time(ofLine: 7))
        #expect(afterStop.project == "sample")
    }

    @Test func runningKeepsItsStartTimeAcrossTools() throws {
        let fixture = try Fixture("claude-code-session-subagent")
        let session = try only(fixture.replay(through: 6))
        #expect(session.phase == .running)
        #expect(session.phaseSince == fixture.time(ofLine: 2))
        #expect(session.openTools.isEmpty)
        #expect(session.recentTools.map(\.name) == ["Bash", "Read"])
    }

    @Test func internalHelperAgentsAreIgnored() throws {
        let fixture = try Fixture("claude-code-session-subagent")
        // Line 8: SubagentStop with agent_type "" right after the Stop.
        let session = try only(fixture.replay(through: 8))
        #expect(session.phase == .yourTurn)
        #expect(session.phaseSince == fixture.time(ofLine: 7))
        #expect(session.subagents.isEmpty)
    }

    @Test func backgroundReviewerIsAChildAndTheMainRowWaitsOnIt() throws {
        let fixture = try Fixture("claude-code-session-subagent")
        // Line 11: PostToolUse(Agent) came before SubagentStart (line 12).
        #expect(try only(fixture.replay(through: 11)).subagents.isEmpty)
        let started = try only(fixture.replay(through: 12))
        #expect(started.subagents.map(\.type) == ["reviewer"])
        #expect(started.phase == .running)

        // Line 16: the main turn stops while the reviewer still runs → not the user's turn yet.
        let store = fixture.replay(through: 16)
        let waiting = try only(store)
        #expect(waiting.phase == .waitingOn("reviewer"))
        #expect(waiting.subagents.first?.phase == .running)
        #expect(!store.needsUser(at: fixture.time(ofLine: 16)))

        // Lines 17–34: an internal SubagentStop and the reviewer's own tools don't touch the main row.
        let stillWaiting = try only(fixture.replay(through: 34))
        #expect(stillWaiting.phase == .waitingOn("reviewer"))
        #expect(stillWaiting.phaseSince == fixture.time(ofLine: 16))
        #expect(stillWaiting.subagents.count == 1)
    }

    @Test func reviewerFinishingHandsBackToTheMainAgent() throws {
        let fixture = try Fixture("claude-code-session-subagent")
        // Line 35: the reviewer's SubagentStop drops the child; the main row still waits…
        let stopped = try only(fixture.replay(through: 35))
        #expect(stopped.subagents.isEmpty)
        #expect(stopped.phase == .waitingOn("reviewer"))
        // …until Claude Code's automatic turn (line 36) and its Stop (line 39).
        #expect(try only(fixture.replay(through: 36)).phase == .running)
        let store = fixture.replay(through: 39)
        #expect(try only(store).phase == .yourTurn)
        #expect(!store.needsUser(at: fixture.time(ofLine: 39)))                        // not in the first 10 s
        #expect(store.needsUser(at: fixture.time(ofLine: 39).addingTimeInterval(10)))
    }

    @Test func sessionEndsOnExit() throws {
        let fixture = try Fixture("claude-code-session-subagent")
        let store = fixture.replay()
        let session = try only(store)
        #expect(session.phase == .ended)
        #expect(session.subagents.isEmpty)
        #expect(!store.needsUser(at: fixture.time(ofLine: fixture.lines.count)))
    }

    // claude-code-permission-approved / -declined: --permission-mode default, async PermissionRequest.

    @Test func approvedPermission() throws {
        let fixture = try Fixture("claude-code-permission-approved")
        let asking = fixture.replay(through: 4)
        #expect(try only(asking).phase == .permission)
        #expect(asking.needsUser(at: fixture.time(ofLine: 4)))
        #expect(try only(fixture.replay(through: 5)).phase == .running)
        #expect(try only(fixture.replay(through: 6)).phase == .yourTurn)
        // Lines 7–8: a helper agent's tool call (agent_id, no agent_type) and its SubagentStop change nothing.
        let after = try only(fixture.replay(through: 8))
        #expect(after.phase == .yourTurn)
        #expect(after.phaseSince == fixture.time(ofLine: 6))
        #expect(after.subagents.isEmpty)
        #expect(try only(fixture.replay()).phase == .ended)
    }

    @Test func declinedPermissionStaysUntilTheNextEvent() throws {
        let fixture = try Fixture("claude-code-permission-declined")
        // A decline fires nothing: the Notification (line 5) keeps it, SessionEnd (line 6) ends it.
        let store = fixture.replay(through: 5)
        let session = try only(store)
        #expect(session.phase == .permission)
        #expect(session.phaseSince == fixture.time(ofLine: 4))
        #expect(store.needsUser(at: fixture.time(ofLine: 5)))
        #expect(try only(fixture.replay()).phase == .ended)
    }

    @Test func permissionArrivingBeforeItsPreToolUseIsKept() throws {
        let fixture = try Fixture("claude-code-permission-approved")
        var lines = fixture.lines
        lines.swapAt(2, 3)  // PermissionRequest before PreToolUse
        var store = AgentSessionStore()
        for line in lines.prefix(4) {
            if let event = AgentEventDecoder.decode(line.body, agent: line.agent, receivedAt: line.time) { store.apply(event) }
        }
        #expect(try only(store).phase == .permission)
    }

    // codex-cli-session: Codex 0.167, three turns, one Esc interrupt, /quit.

    @Test func codexTurnsAndInterrupt() throws {
        let fixture = try Fixture("codex-cli-session")
        #expect(try only(fixture.replay(through: 5)).phase == .yourTurn)
        // Line 9: a Bash call that never finishes; line 10: Interrupt closes it.
        #expect(try only(fixture.replay(through: 9)).openTools.count == 1)
        let interrupted = try only(fixture.replay(through: 10))
        #expect(interrupted.phase == .yourTurn)
        #expect(interrupted.openTools.isEmpty)
        #expect(try only(fixture.replay(through: 20)).phase == .yourTurn)
        let ended = try only(fixture.replay())
        #expect(ended.phase == .ended)
        #expect(ended.agent == .codex)
        #expect(ended.subagents.isEmpty)
    }
}

struct AgentSessionClockTests {
    private func event(_ kind: AgentEvent.Kind, _ session: String = "s1", at time: Date,
                       agent: AgentKind = .claudeCode) -> AgentEvent {
        AgentEvent(agent: agent, sessionID: session, kind: kind, time: time, cwd: "/tmp/demo")
    }

    @Test func staleThenHiddenThenSwept() {
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        var store = AgentSessionStore()
        store.apply(event(.promptSubmitted, at: t0))
        store.apply(event(.turnEnded(backgroundTasks: []), at: t0))
        let session = store.sessions.values.first!

        #expect(store.displayState(of: session, at: t0.addingTimeInterval(29 * 60)) == .phase(.yourTurn))
        #expect(store.needsUser(at: t0.addingTimeInterval(29 * 60)))
        #expect(store.displayState(of: session, at: t0.addingTimeInterval(31 * 60)) == .stale)
        #expect(!store.needsUser(at: t0.addingTimeInterval(31 * 60)))
        #expect(store.visibleSessions(at: t0.addingTimeInterval(119 * 60)).count == 1)
        #expect(store.visibleSessions(at: t0.addingTimeInterval(121 * 60)).isEmpty)

        store.sweep(at: t0.addingTimeInterval(119 * 60))
        #expect(store.sessions.count == 1)
        store.sweep(at: t0.addingTimeInterval(121 * 60))
        #expect(store.sessions.isEmpty)
    }

    @Test func endedSessionsLeaveAfterTenMinutesAndNeverGoStale() {
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        var store = AgentSessionStore()
        store.apply(event(.promptSubmitted, at: t0))
        store.apply(event(.sessionEnded, at: t0))
        let session = store.sessions.values.first!
        #expect(store.displayState(of: session, at: t0.addingTimeInterval(9 * 60)) == .phase(.ended))
        #expect(store.visibleSessions(at: t0.addingTimeInterval(11 * 60)).isEmpty)
    }

    @Test func endForAnUnknownSessionCreatesNothing() {
        var store = AgentSessionStore()
        store.apply(event(.sessionEnded, at: .now))
        #expect(store.sessions.isEmpty)
    }

    @Test func sessionsAreKeyedByAgentToo() {
        var store = AgentSessionStore()
        store.apply(event(.promptSubmitted, "same-id", at: .now))
        store.apply(event(.promptSubmitted, "same-id", at: .now, agent: .codex))
        #expect(store.sessions.count == 2)
    }

    @Test func storeKeepsAtMostAHundredSessions() {
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        var store = AgentSessionStore()
        for i in 0..<120 { store.apply(event(.promptSubmitted, "s\(i)", at: t0.addingTimeInterval(Double(i)))) }
        #expect(store.sessions.count == 100)
        #expect(store.sessions[AgentSession.Key(agent: .claudeCode, sessionID: "s0")] == nil)
        #expect(store.sessions[AgentSession.Key(agent: .claudeCode, sessionID: "s119")] != nil)
    }

    @Test func subagentPermissionCountsForTheSession() {
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        var store = AgentSessionStore()
        store.apply(event(.promptSubmitted, at: t0))
        var start = event(.subagentStarted, at: t0)
        start.subagentID = "a1"; start.subagentType = "reviewer"
        store.apply(start)
        store.apply(event(.turnEnded(backgroundTasks: [.init(id: "t1", type: "subagent", status: "running",
                                                              description: nil, agentType: "reviewer")]), at: t0))
        var ask = event(.permissionRequested, at: t0)
        ask.subagentID = "a1"; ask.subagentType = "reviewer"
        store.apply(ask)
        let session = store.sessions.values.first!
        #expect(session.phase == .waitingOn("reviewer"))
        #expect(store.displayState(of: session, at: t0) == .phase(.permission))
        #expect(store.needsUser(at: t0))
    }

    private func tool(_ kind: AgentEvent.Kind, _ name: String, id: String, at time: Date) -> AgentEvent {
        var e = event(kind, at: time)
        e.toolName = name; e.toolUseID = id
        return e
    }

    @Test func yourTurnBadgeWaitsTenSecondsAndPermissionDoesnt() {
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        var store = AgentSessionStore()
        store.apply(event(.promptSubmitted, at: t0))
        store.apply(event(.turnEnded(backgroundTasks: []), at: t0))
        #expect(!store.needsUser(at: t0.addingTimeInterval(9)))
        // It runs again within the 10 s: no badge at all.
        store.apply(event(.promptSubmitted, at: t0.addingTimeInterval(5)))
        #expect(!store.needsUser(at: t0.addingTimeInterval(12)))
        store.apply(event(.turnEnded(backgroundTasks: []), at: t0.addingTimeInterval(20)))
        #expect(store.needsUser(at: t0.addingTimeInterval(30)))
        store.apply(event(.permissionRequested, at: t0.addingTimeInterval(31)))
        #expect(store.needsUser(at: t0.addingTimeInterval(31)))
    }

    @Test func keepsTheAgentsOwnTitle() {
        var store = AgentSessionStore()
        var start = event(.promptSubmitted, at: .now)
        start.title = "Retry work"
        store.apply(start)
        #expect(store.sessions.values.first?.title == "Retry work")
        #expect(AgentEventDecoder.decode(Data(#"{"session_id":"s","hook_event_name":"UserPromptSubmit","session_title":"T"}"#.utf8),
                                         agent: .claudeCode, receivedAt: .now)?.title == "T")
    }

    @Test func newSessionIsIdleWithoutBadge() {
        var store = AgentSessionStore()
        store.apply(event(.sessionStarted, at: .now))
        #expect(store.sessions.values.first?.phase == .idle)
        #expect(!store.needsUser(at: .now))
    }

    @Test func lateEventsDontReviveAnEndedSession() {
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        var store = AgentSessionStore()
        store.apply(event(.promptSubmitted, at: t0))
        store.apply(tool(.toolStarted, "Bash", id: "u1", at: t0))
        store.apply(event(.sessionEnded, at: t0))
        store.apply(tool(.toolFinished, "Bash", id: "u1", at: t0))
        store.apply(tool(.toolStarted, "Bash", id: "u2", at: t0))
        var start = event(.subagentStarted, at: t0)
        start.subagentID = "a1"; start.subagentType = "reviewer"
        store.apply(start)
        store.apply(event(.turnEnded(backgroundTasks: []), at: t0))
        #expect(store.sessions.values.first?.phase == .ended)
        #expect(store.sessions.values.first?.subagents.isEmpty == true)
        // A new prompt (a resumed session) brings it back.
        store.apply(event(.promptSubmitted, at: t0))
        #expect(store.sessions.values.first?.phase == .running)
    }

    @Test func latePostToolUseKeepsYourTurn() {
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        var store = AgentSessionStore()
        store.apply(event(.promptSubmitted, at: t0))
        store.apply(tool(.toolStarted, "Bash", id: "u1", at: t0))
        store.apply(event(.turnEnded(backgroundTasks: []), at: t0))
        store.apply(tool(.toolFinished, "Bash", id: "u1", at: t0.addingTimeInterval(1)))
        #expect(store.sessions.values.first?.phase == .yourTurn)
    }

    @Test func permissionPromptNotificationMeansPermission() {
        var store = AgentSessionStore()
        store.apply(event(.promptSubmitted, at: .now))
        store.apply(event(.notification(type: "permission_prompt"), at: .now))
        #expect(store.sessions.values.first?.phase == .permission)
        store.apply(event(.notification(type: "idle_prompt"), at: .now))
        #expect(store.sessions.values.first?.phase == .permission)
    }

    @Test func newPromptAfterADeclineRuns() {
        var store = AgentSessionStore()
        store.apply(event(.promptSubmitted, at: .now))
        store.apply(tool(.toolStarted, "Bash", id: "u1", at: .now))
        store.apply(tool(.permissionRequested, "Bash", id: "", at: .now))
        store.apply(event(.promptSubmitted, at: .now))
        #expect(store.sessions.values.first?.phase == .running)
    }

    @Test func anotherToolStartingEndsTheWait() {
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        // A different tool.
        var store = AgentSessionStore()
        store.apply(event(.promptSubmitted, at: t0))
        store.apply(tool(.permissionRequested, "Bash", id: "", at: t0))
        store.apply(tool(.toolStarted, "Read", id: "u1", at: t0))
        #expect(store.sessions.values.first?.phase == .running)
        // A second call of the same tool while the first is open.
        store = AgentSessionStore()
        store.apply(event(.promptSubmitted, at: t0))
        store.apply(tool(.toolStarted, "Bash", id: "u1", at: t0))
        store.apply(tool(.permissionRequested, "Bash", id: "", at: t0))
        store.apply(tool(.toolStarted, "Bash", id: "u2", at: t0))
        #expect(store.sessions.values.first?.phase == .running)
    }

    @Test func runningDevServerDoesntHoldTheTurn() {
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        var store = AgentSessionStore()
        store.apply(event(.promptSubmitted, at: t0))
        store.apply(event(.turnEnded(backgroundTasks: [
            .init(id: "t1", type: "shell", status: "running", description: "npm run dev")]), at: t0))
        let session = store.sessions.values.first!
        #expect(session.phase == .yourTurn)
        #expect(session.backgroundNote == "npm run dev")
        #expect(store.needsUser(at: t0.addingTimeInterval(10)))
        // The note goes with the next prompt.
        store.apply(event(.promptSubmitted, at: t0))
        #expect(store.sessions.values.first?.backgroundNote == nil)
    }

    @Test func workflowsAndTeammatesHoldTheTurnLikeSubagents() {
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        var store = AgentSessionStore()
        store.apply(event(.promptSubmitted, at: t0))
        store.apply(event(.turnEnded(backgroundTasks: [
            .init(id: "t1", type: "monitor", status: "running", description: "watch CI"),
            .init(id: "t2", type: "workflow", status: "running", description: "Review", name: "review-changes")]), at: t0))
        let session = store.sessions.values.first!
        #expect(session.phase == .waitingOn("review-changes"))
        #expect(session.backgroundNote == "watch CI")
        #expect(!store.needsUser(at: t0))
    }

    @Test func codexHasNoSubagentRows() {
        var store = AgentSessionStore()
        store.apply(event(.promptSubmitted, at: .now, agent: .codex))
        var start = event(.subagentStarted, at: .now, agent: .codex)
        start.subagentID = "a1"; start.subagentType = "worker"
        store.apply(start)
        #expect(store.sessions.values.first?.subagents.isEmpty == true)
    }
}

struct AgentEventDecoderTests {
    private func decode(_ json: String, agent: AgentKind = .claudeCode) -> AgentEvent? {
        AgentEventDecoder.decode(Data(json.utf8), agent: agent, receivedAt: .now)
    }

    @Test func rejectsWhatIsntAnEvent() {
        #expect(decode("not json") == nil)
        #expect(decode("[]") == nil)
        #expect(decode(#"{"hook_event_name":"Stop"}"#) == nil)                          // no session
        #expect(decode(#"{"session_id":"s","hook_event_name":"SomethingNew"}"#) == nil)  // unknown hook
        #expect(decode(#"{"session_id":"s","hook_event_name":"Notification"}"#) == nil)  // no type
    }

    @Test func helperAgentEventsAreDropped() {
        #expect(decode(#"{"session_id":"s","hook_event_name":"SubagentStop","agent_id":"a","agent_type":""}"#) == nil)
        #expect(decode(#"{"session_id":"s","hook_event_name":"PreToolUse","agent_id":"a","tool_name":"X"}"#) == nil)
        #expect(decode(#"{"session_id":"s","hook_event_name":"SubagentStart","agent_id":"a","agent_type":"reviewer"}"#)?
            .subagentType == "reviewer")
    }

    @Test func stopCarriesBackgroundTasks() throws {
        let event = try #require(decode(#"""
            {"session_id":"s","hook_event_name":"Stop","background_tasks":[
             {"id":"t1","type":"subagent","status":"running","description":"Review","agent_type":"reviewer"},
             {"id":"t2","type":"shell","status":"completed","description":"Build"}]}
            """#))
        guard case .turnEnded(let tasks) = event.kind else { Issue.record("not a turn end"); return }
        #expect(tasks.count == 2)
        #expect(tasks.filter(\.isRunning).map(\.label) == ["reviewer"])
        #expect(AgentEvent.BackgroundTask(id: "x", status: "running", description: "Build").label == "Build")
    }

    @Test func toolSummaryIsShortAndSingleLine() {
        #expect(AgentEventDecoder.summary(of: ["command": "swift test\necho done"]) == "swift test")
        #expect(AgentEventDecoder.summary(of: ["file_path": "/a/b/Package.swift"]) == "Package.swift")
        #expect(AgentEventDecoder.summary(of: ["command": String(repeating: "x", count: 200)])?.count == 80)
        #expect(AgentEventDecoder.summary(of: ["other": 1]) == nil)
    }

    @Test func codexFailureAndInterruptMap() {
        #expect(decode(#"{"session_id":"s","hook_event_name":"Interrupt","turn_id":"t"}"#, agent: .codex)?.kind == .interrupted)
        #expect(decode(#"{"session_id":"s","hook_event_name":"PostToolUseFailure","tool_use_id":"u"}"#)?.kind == .toolFinished)
    }

    @Test func descriptionOnlyFromToolsWhereItDescribesTheCall() {
        let bash = decode(#"{"session_id":"s","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"git push","description":"Push to origin"}}"#)
        #expect(bash?.toolDescription == "Push to origin")
        let mcp = decode(#"{"session_id":"s","hook_event_name":"PermissionRequest","tool_name":"mcp__x__create_issue","tool_input":{"description":"The login page crashes"}}"#)
        #expect(mcp?.toolDescription == nil)
    }

    @Test func stopFailureEndsTheTurn() {
        #expect(decode(#"{"session_id":"s","hook_event_name":"StopFailure","error":"rate_limit"}"#)?.kind
            == .turnEnded(backgroundTasks: []))
    }
}
