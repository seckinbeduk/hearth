import Foundation

/// What one agent session (or subagent) is doing.
enum AgentPhase: Sendable, Equatable {
    /// Started, no prompt yet.
    case idle
    /// A prompt was submitted or a tool is in progress.
    case running
    /// The agent asked for permission and waits for the user.
    case permission
    /// The turn is over and nothing runs in the background: the user's move.
    case yourTurn
    /// The turn is over but a subagent, workflow or teammate still runs; the agent continues by itself
    /// when it finishes.
    case waitingOn(String)
    case ended
}

/// What the panel shows for a session: its phase, or `stale` when it has been quiet too long.
enum AgentDisplayState: Sendable, Equatable {
    case phase(AgentPhase)
    case stale

    /// Counts for the menu bar badge: the user is needed.
    var needsUser: Bool {
        switch self {
        case .phase(.permission), .phase(.yourTurn): true
        default: false
        }
    }
}

struct AgentSubagent: Sendable, Equatable, Identifiable {
    var id: String
    var type: String
    var phase: AgentPhase
    var phaseSince: Date
    var startedAt: Date
}

struct AgentSession: Sendable, Equatable, Identifiable {
    struct Key: Hashable, Sendable {
        var agent: AgentKind
        var sessionID: String
    }

    struct Tool: Sendable, Equatable {
        var name: String
        var summary: String?
    }

    var id: Key
    var cwd: String?
    var phase: AgentPhase
    var phaseSince: Date
    var startedAt: Date
    var lastEventAt: Date
    /// Running subagents in start order (Claude Code only).
    var subagents: [AgentSubagent] = []
    /// Main-agent tools started and not finished yet, by tool_use_id.
    var openTools: [String: Tool] = [:]
    /// Inputs for the summary line: newest last.
    var recentTools: [Tool] = []
    var lastPrompt: String?
    var lastMessage: String?
    /// The tool of the latest permission request (main agent).
    var permissionTool: String?
    /// The pending tool's short hint ("git push"), for the permission line.
    var permissionHint: String?
    /// The agent's own description of the pending call ("Create a test file on the Desktop"), if it sent one.
    var permissionDescription: String?
    /// The last turn was cut short (Codex Interrupt, Claude Code StopFailure).
    var stoppedEarly = false
    /// The agent's own title for the session, if any; shown until the first summary.
    var title: String?
    /// Background work that doesn't hold the turn, e.g. a dev server: shown as "running: …" in the row.
    var backgroundNote: String?

    /// Where the session started; the project it's named after.
    var firstCwd: String?

    var agent: AgentKind { id.agent }
    /// The project: the last path component of the folder the session started in.
    var project: String { (firstCwd ?? cwd).map { ($0 as NSString).lastPathComponent } ?? "" }
    /// The folder it works in now, when that's another one ("coding → Hearth").
    var currentProject: String? {
        guard let cwd, let firstCwd, cwd != firstCwd else { return nil }
        let name = (cwd as NSString).lastPathComponent
        return name == project ? nil : name
    }

    /// A subagent asking for permission counts for the whole session.
    var effectivePhase: AgentPhase {
        if subagents.contains(where: { $0.phase == .permission }) && phase != .ended { return .permission }
        return phase
    }
}

/// All agent sessions Hearth knows about, driven by hook events. Pure value type: the time comes in
/// with each event and with each query, so tests replay recordings with an injected clock.
/// In memory only; nothing here is ever written to disk or logged.
struct AgentSessionStore: Sendable, Equatable {
    static let staleAfter: TimeInterval = 30 * 60
    static let hiddenAfter: TimeInterval = 2 * 60 * 60
    static let endedHiddenAfter: TimeInterval = 10 * 60
    static let maxSessions = 100
    static let recentToolCount = 5
    /// "Your turn" lights the badge only after this long: a turn that ends and goes on at once
    /// (an automatic follow-up) shouldn't flash it. Permission lights it at once.
    static let yourTurnBadgeDelay: TimeInterval = 10

    private(set) var sessions: [AgentSession.Key: AgentSession] = [:]

    mutating func apply(_ event: AgentEvent) {
        let key = AgentSession.Key(agent: event.agent, sessionID: event.sessionID)
        guard var session = sessions[key] ?? newSession(for: event, key: key) else { return }
        session.lastEventAt = max(session.lastEventAt, event.time)
        if let cwd = event.cwd, event.subagentID == nil {
            session.cwd = cwd
            if session.firstCwd == nil { session.firstCwd = cwd }
        }
        if let title = event.title, event.subagentID == nil { session.title = title }

        if let subagentID = event.subagentID, event.kind != .subagentStarted, event.kind != .subagentStopped {
            applySubagentEvent(event, id: subagentID, to: &session)
        } else {
            applyMainEvent(event, to: &session)
        }
        sessions[key] = session
        trim()
    }

    /// Sessions to show at `now`, newest activity first. Hidden ones are left out.
    func visibleSessions(at now: Date) -> [AgentSession] {
        sessions.values
            .filter { !Self.isHidden($0, at: now) }
            .sorted { $0.lastEventAt > $1.lastEventAt }
    }

    func displayState(of session: AgentSession, at now: Date) -> AgentDisplayState {
        if session.phase != .ended, now.timeIntervalSince(session.lastEventAt) > Self.staleAfter { return .stale }
        return .phase(session.effectivePhase)
    }

    /// The menu bar badge: any visible session needs the user ("your turn" after a short delay).
    func needsUser(at now: Date) -> Bool {
        visibleSessions(at: now).contains { session in
            switch displayState(of: session, at: now) {
            case .phase(.permission): true
            case .phase(.yourTurn): now.timeIntervalSince(session.phaseSince) >= Self.yourTurnBadgeDelay
            default: false
            }
        }
    }

    /// Drops hidden sessions so memory stays bounded. Call from a timer.
    mutating func sweep(at now: Date) {
        sessions = sessions.filter { !Self.isHidden($0.value, at: now) }
    }

    // MARK: - Transitions

    private func newSession(for event: AgentEvent, key: AgentSession.Key) -> AgentSession? {
        // An end for a session we never saw has nothing to show.
        if event.kind == .sessionEnded { return nil }
        return AgentSession(id: key, cwd: event.cwd, phase: .idle, phaseSince: event.time,
                            startedAt: event.time, lastEventAt: event.time, firstCwd: event.subagentID == nil ? event.cwd : nil)
    }

    private func applyMainEvent(_ event: AgentEvent, to session: inout AgentSession) {
        // Forwarders are independent processes: a late tool event must not revive an ended session.
        // Only a new prompt does (e.g. a resumed session id).
        if session.phase == .ended, event.kind != .promptSubmitted { return }
        switch event.kind {
        case .sessionStarted:
            break
        case .sessionEnded:
            session.openTools = [:]
            session.subagents = []
            set(.ended, on: &session, at: event.time)
        case .promptSubmitted:
            session.lastPrompt = event.prompt
            session.stoppedEarly = false
            session.backgroundNote = nil
            set(.running, on: &session, at: event.time)
        case .toolStarted:
            if let tool = tool(of: event) {
                if let id = event.toolUseID { session.openTools[id] = tool }
                remember(tool, in: &session)
            }
            // A PermissionRequest can arrive before its own PreToolUse (independent forwarders):
            // that PreToolUse must not end the wait. It's the only open call of that tool.
            if session.phase == .permission, session.permissionTool == event.toolName,
               !session.openTools.contains(where: { $0.key != event.toolUseID && $0.value.name == event.toolName }) {
                break
            }
            set(.running, on: &session, at: event.time)
        case .toolFinished:
            // A late PostToolUse after the turn ended (open tools already cleared) changes nothing.
            let wasOpen = event.toolUseID.flatMap { session.openTools.removeValue(forKey: $0) } != nil
            if wasOpen || session.phase == .permission { set(.running, on: &session, at: event.time) }
        case .permissionRequested:
            session.permissionTool = event.toolName
            session.permissionHint = event.toolSummary
            session.permissionDescription = event.toolDescription
            set(.permission, on: &session, at: event.time)
        case .notification(let type):
            if type == "permission_prompt", session.phase != .ended { set(.permission, on: &session, at: event.time) }
        case .turnEnded(let tasks):
            session.openTools = [:]
            session.stoppedEarly = event.failed
            if let message = event.lastMessage { session.lastMessage = message }
            let running = tasks.filter(\.isRunning)
            session.backgroundNote = running.first { !$0.holdsTurn }.map(\.label)
            if let busy = running.first(where: \.holdsTurn) {
                set(.waitingOn(busy.label), on: &session, at: event.time)
            } else {
                set(.yourTurn, on: &session, at: event.time)
            }
        case .interrupted:
            session.openTools = [:]
            session.stoppedEarly = true
            set(.yourTurn, on: &session, at: event.time)
        case .subagentStarted:
            guard session.agent.hasSubagents, let id = event.subagentID, let type = event.subagentType else { return }
            if !session.subagents.contains(where: { $0.id == id }) {
                session.subagents.append(AgentSubagent(id: id, type: type, phase: .running,
                                                       phaseSince: event.time, startedAt: event.time))
            }
        case .subagentStopped:
            // Never create a row from a stop alone; just drop the child if we have it.
            if let id = event.subagentID { session.subagents.removeAll { $0.id == id } }
        }
    }

    private func applySubagentEvent(_ event: AgentEvent, id: String, to session: inout AgentSession) {
        guard session.agent.hasSubagents, session.phase != .ended else { return }
        // Hearth may have started after the subagent did: adopt it on its first event.
        if !session.subagents.contains(where: { $0.id == id }), let type = event.subagentType {
            session.subagents.append(AgentSubagent(id: id, type: type, phase: .running,
                                                   phaseSince: event.time, startedAt: event.time))
        }
        guard let index = session.subagents.firstIndex(where: { $0.id == id }) else { return }
        let next: AgentPhase
        switch event.kind {
        case .permissionRequested: next = .permission
        case .notification: return
        case .toolStarted where session.subagents[index].phase == .permission: return
        default: next = .running
        }
        if session.subagents[index].phase != next {
            session.subagents[index].phase = next
            session.subagents[index].phaseSince = event.time
        }
    }

    private func set(_ phase: AgentPhase, on session: inout AgentSession, at time: Date) {
        guard session.phase != phase else { return }
        if session.phase == .permission {
            session.permissionTool = nil
            session.permissionHint = nil
            session.permissionDescription = nil
        }
        session.phase = phase
        session.phaseSince = time
    }

    private func tool(of event: AgentEvent) -> AgentSession.Tool? {
        event.toolName.map { AgentSession.Tool(name: $0, summary: event.toolSummary) }
    }

    private func remember(_ tool: AgentSession.Tool, in session: inout AgentSession) {
        session.recentTools.append(tool)
        if session.recentTools.count > Self.recentToolCount {
            session.recentTools.removeFirst(session.recentTools.count - Self.recentToolCount)
        }
    }

    private static func isHidden(_ session: AgentSession, at now: Date) -> Bool {
        let quiet = now.timeIntervalSince(session.lastEventAt)
        return session.phase == .ended ? quiet > endedHiddenAfter : quiet > hiddenAfter
    }

    private mutating func trim() {
        guard sessions.count > Self.maxSessions else { return }
        let oldest = sessions.values.sorted { $0.lastEventAt < $1.lastEventAt }.prefix(sessions.count - Self.maxSessions)
        for session in oldest { sessions[session.id] = nil }
    }
}
