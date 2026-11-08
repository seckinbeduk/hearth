import Foundation

/// A coding agent whose hooks can report to Hearth. One case per supported tool.
enum AgentKind: String, Sendable, CaseIterable, Codable {
    case claudeCode = "claude-code"
    case codex

    var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        }
    }

    /// The endpoint path the agent's hooks post to (`/agents/claude-code`, `/agents/codex`).
    var path: String { "/agents/\(rawValue)" }

    /// Whether the agent reports subagents (only Claude Code in v1).
    var hasSubagents: Bool { self == .claudeCode }
}

/// One hook event, normalized across agents. Built from the hook's JSON payload and kept in memory only.
struct AgentEvent: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case sessionStarted
        case sessionEnded
        case promptSubmitted
        case toolStarted
        case toolFinished
        case permissionRequested
        /// `Stop` / `StopFailure` (Claude Code), `Stop` (Codex): the turn is over. Lists background work still running.
        case turnEnded(backgroundTasks: [BackgroundTask])
        /// Codex's `Interrupt`: the user cut the turn short.
        case interrupted
        case subagentStarted
        case subagentStopped
        case notification(type: String)
    }

    struct BackgroundTask: Sendable, Equatable {
        var id: String
        var type: String?
        var status: String?
        var description: String?
        var agentType: String?
        /// Workflow name (workflow tasks only).
        var name: String?

        var isRunning: Bool { status == "running" }
        /// Agent work that resumes the turn by itself when it finishes. Shells, monitors and the rest may run
        /// for good (a dev server), so they don't hold the turn.
        var holdsTurn: Bool { ["subagent", "workflow", "teammate"].contains(type ?? "") }
        /// What the session waits on or runs: the subagent's type, the workflow's name, else the description.
        var label: String { [agentType, name, description].compactMap { $0 }.first { !$0.isEmpty } ?? "a background task" }
    }

    var agent: AgentKind
    var sessionID: String
    var kind: Kind
    var time: Date
    var cwd: String?
    /// Set when the event comes from inside a subagent (Claude Code).
    var subagentID: String?
    var subagentType: String?
    var toolName: String?
    var toolUseID: String?
    /// A short, single-line hint of what the tool does (command, file name, …), for the summary line.
    var toolSummary: String?
    var prompt: String?
    var lastMessage: String?
    /// The turn ended on an error (Claude Code's StopFailure) rather than normally.
    var failed = false
    /// The agent's own session title, when the user set one (Claude Code's `session_title`).
    var title: String?
}

/// Turns hook payloads into `AgentEvent`s. Both agents use the same field names, so one decoder serves both.
enum AgentEventDecoder {
    /// `nil` for anything that isn't a usable event: malformed JSON, no session id, an unknown hook,
    /// or an event from one of Claude Code's own helper agents (an `agent_id` without an `agent_type`).
    static func decode(_ data: Data, agent: AgentKind, receivedAt time: Date) -> AgentEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let body = object as? [String: Any],
              let sessionID = body["session_id"] as? String, !sessionID.isEmpty,
              let name = body["hook_event_name"] as? String,
              let kind = kind(for: name, body: body)
        else { return nil }

        let subagentID = nonEmpty(body["agent_id"])
        let subagentType = nonEmpty(body["agent_type"])
        if subagentID != nil, subagentType == nil { return nil }

        let toolInput = body["tool_input"] as? [String: Any]
        return AgentEvent(
            agent: agent, sessionID: sessionID, kind: kind, time: time,
            cwd: nonEmpty(body["cwd"]),
            subagentID: subagentID, subagentType: subagentType,
            toolName: nonEmpty(body["tool_name"]),
            toolUseID: nonEmpty(body["tool_use_id"]),
            toolSummary: toolInput.flatMap(summary(of:)),
            prompt: nonEmpty(body["prompt"]),
            lastMessage: nonEmpty(body["last_assistant_message"]),
            failed: name == "StopFailure", title: nonEmpty(body["session_title"]))
    }

    private static func kind(for name: String, body: [String: Any]) -> AgentEvent.Kind? {
        switch name {
        case "SessionStart": .sessionStarted
        case "SessionEnd": .sessionEnded
        case "UserPromptSubmit": .promptSubmitted
        case "PreToolUse": .toolStarted
        case "PostToolUse", "PostToolUseFailure": .toolFinished
        case "PermissionRequest": .permissionRequested
        // StopFailure replaces Stop when the turn ends on an API error (rate limit, overload…).
        case "Stop", "StopFailure": .turnEnded(backgroundTasks: backgroundTasks(body["background_tasks"]))
        case "Interrupt": .interrupted
        case "SubagentStart": .subagentStarted
        case "SubagentStop": .subagentStopped
        case "Notification": nonEmpty(body["notification_type"]).map { .notification(type: $0) }
        default: nil
        }
    }

    private static func backgroundTasks(_ value: Any?) -> [AgentEvent.BackgroundTask] {
        guard let items = value as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let id = nonEmpty(item["id"]) else { return nil }
            return AgentEvent.BackgroundTask(
                id: id, type: nonEmpty(item["type"]), status: nonEmpty(item["status"]),
                description: nonEmpty(item["description"]), agentType: nonEmpty(item["agent_type"]),
                name: nonEmpty(item["name"]))
        }
    }

    /// The most telling input field, first line only, at most 80 characters.
    static func summary(of input: [String: Any]) -> String? {
        for key in ["command", "file_path", "path", "pattern", "subagent_type", "url", "query"] {
            guard var value = nonEmpty(input[key]) else { continue }
            if key == "file_path" || key == "path" { value = (value as NSString).lastPathComponent }
            let line = value.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? value
            return line.count > 80 ? String(line.prefix(79)) + "…" : line
        }
        return nil
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }
}
