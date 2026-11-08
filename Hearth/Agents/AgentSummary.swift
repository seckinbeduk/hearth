import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// What the summary line is written from: the session's recent events, nothing else (no transcripts).
struct AgentSummaryInput: Sendable, Equatable {
    var agent: AgentKind
    var project: String
    var phase: AgentPhase
    var prompt: String?
    /// The latest prompt came from the agent itself (a subagent's result, a task notification), not the user.
    var promptIsAutomatic: Bool
    var tools: [AgentSession.Tool]
    var lastMessage: String?
    var subagents: [String]

    static let maxCharacters = 3_000

    init(agent: AgentKind, project: String, phase: AgentPhase, prompt: String?, promptIsAutomatic: Bool = false,
         tools: [AgentSession.Tool] = [], lastMessage: String? = nil, subagents: [String] = []) {
        self.agent = agent
        self.project = project
        self.phase = phase
        self.prompt = prompt
        self.promptIsAutomatic = promptIsAutomatic
        self.tools = tools
        self.lastMessage = lastMessage
        self.subagents = subagents
    }

    init(session: AgentSession) {
        self.init(agent: session.agent, project: session.project, phase: session.phase, prompt: session.lastPrompt,
                  promptIsAutomatic: session.lastPrompt.map(Self.isAutomatic) ?? false, tools: session.recentTools,
                  lastMessage: session.lastMessage, subagents: session.subagents.map(\.type))
    }

    /// Tags Claude Code wraps its own turns in (a subagent's result, a task notification, another session).
    static let automaticTags: Set<String> = ["agent-message", "task-notification", "cross-session-message",
                                             "system-reminder", "scheduled-task", "loop-iteration"]

    static func isAutomatic(_ prompt: String) -> Bool {
        guard let match = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            .prefixMatch(of: /<([a-z][a-z0-9_-]*)[\s>]/) else { return false }
        return automaticTags.contains(String(match.output.1))
    }

    /// The prompt for the model, trimmed hard. Paths are cut to file names; nothing else is added.
    var promptText: String {
        var parts: [String] = ["Agent: \(agent.displayName)", "Project: \(project.isEmpty ? "unknown" : project)",
                               "State: \(Self.describe(phase))", "Write: \(Self.task(for: phase))"]
        if !subagents.isEmpty { parts.append("Subagents running: " + subagents.joined(separator: ", ")) }
        if let prompt {
            let label = promptIsAutomatic
                ? "Latest message to the agent (automatic, from the agent itself, not from the user)"
                : "The user's latest request"
            parts.append("\(label):\n" + Self.clean(prompt, limit: 1_200))
        }
        if !tools.isEmpty {
            parts.append("Recent tool calls, oldest first:\n" + tools.map { tool in
                "- " + tool.name + (tool.summary.map { ": " + Self.clean($0, limit: 120) } ?? "")
            }.joined(separator: "\n"))
        }
        if let lastMessage { parts.append("The agent's last message:\n" + Self.clean(lastMessage, limit: 800)) }
        return String(parts.joined(separator: "\n\n").prefix(Self.maxCharacters))
    }

    static func describe(_ phase: AgentPhase) -> String {
        switch phase {
        case .idle: "just started"
        case .running: "working"
        case .permission: "waiting for the user's permission"
        case .yourTurn: "finished its turn, waiting for the user"
        case .waitingOn(let task): "waiting for \(task) to finish"
        case .ended: "ended"
        }
    }

    /// Masks the obvious secret shapes: `NAME=value` where the name says token/key/secret/password/auth/credential,
    /// `Bearer …`, `--token …` / `--password …` / `--api-key …`, and `user:password@` in URLs. Not a guarantee
    /// (a bare token argument stays), but it keeps the common cases out of the model and the fallback line.
    static func maskSecrets(_ text: String) -> String {
        text
            // Environment variables: upper-case names only, so flags like --author= or --key=2 stay.
            .replacing(/\b([A-Z0-9_]*(?:TOKEN|KEY|SECRET|PASS|PASSWORD|AUTH|CREDENTIAL)[A-Z0-9_]*)=("[^"]*"|'[^']*'|\S+)/) {
                "\($0.output.1)=…"
            }
            // Lower-case: exact names only (query strings, config lines).
            .replacing(/(^|[^\w-])(token|api_?key|apikey|password|passwd|secret|access_token|auth_token)=[^\s&"']+/) {
                "\($0.output.1)\($0.output.2)=…"
            }
            .replacing(/(?i)\bBearer\s+[^\s'"]+/) { _ in "Bearer …" }
            .replacing(/(?i)(--(?:token|password|passwd|api-key|apikey|secret)(?:=|\s+))\S+/) { "\($0.output.1)…" }
            .replacing(/:\/\/([^\/\s:@]+):[^\/\s@]+@/) { "://\($0.output.1):…@" }
    }

    /// What the line should say in each state.
    static func task(for phase: AgentPhase) -> String {
        switch phase {
        case .idle, .running: "what the agent is working on right now"
        case .permission: "what the agent wants permission to do"
        case .yourTurn: "what the agent just finished, or what it asks the user, judging by its last message"
        case .waitingOn(let task): "that the agent waits for \(task), and on what work"
        case .ended: "that the session ended"
        }
    }

    /// Secrets are masked, paths become file names, whitespace collapses, and the text is cut to `limit`.
    static func clean(_ text: String, limit: Int) -> String {
        let masked = maskSecrets(text)
        let noPaths = masked.replacing(/(?:~|\.{1,2})?(?:\/[^\s\/"'`<>]+)+\/([^\s\/"'`<>]+)/) { String($0.output.1) }
        let flat = noPaths.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }
}

/// Writes the one-line summary. The real one uses Apple Intelligence; tests use a fake.
protocol AgentSummarizer: Sendable {
    func summarize(_ input: AgentSummaryInput) async throws -> String
}

enum AgentSummaryLine {
    static let maxLength = 70

    /// One line, no quotes, at most 70 characters (cut at a word), or nil if nothing usable is left.
    static func tidy(_ raw: String) -> String? {
        var line = raw.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        line = line.trimmingCharacters(in: .whitespaces)
        line = line.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’`*"))
        line = line.replacingOccurrences(of: "\"", with: "")
        if line.hasSuffix(".") && !line.hasSuffix("...") { line.removeLast() }
        line = line.trimmingCharacters(in: .whitespaces)
        guard let first = line.first else { return nil }
        line = first.uppercased() + line.dropFirst()
        guard line.count > maxLength else { return line }
        let cut = line.prefix(maxLength - 1)
        let word = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return word.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters)) + "…"
    }

    /// Used when Apple Intelligence is unavailable or fails: the last tool and its hint.
    static func fallback(for input: AgentSummaryInput) -> String? {
        guard let tool = input.tools.last else { return nil }
        let hint = tool.summary.map { AgentSummaryInput.clean($0, limit: 50) }
        let verb: String
        switch tool.name {
        case "Bash", "shell", "exec_command", "local_shell": verb = "Running"
        case "Read", "Grep", "Glob", "LS": verb = "Reading"
        case "Edit", "Write", "MultiEdit", "NotebookEdit", "apply_patch": verb = "Editing"
        case "Agent", "Task": verb = "Starting"
        case "WebFetch", "WebSearch": verb = "Looking up"
        default: return tidy("Using \(tool.name)" + (hint.map { ": \($0)" } ?? ""))
        }
        return tidy(hint.map { "\(verb) \($0)" } ?? "\(verb) (\(tool.name))")
    }
}

/// Apple Intelligence, on-device. Never the local MLX model, never the network.
struct AppleAgentSummarizer: AgentSummarizer {
    struct Unavailable: Error {}

    // No example sentences here: a small model copies them when the input is thin (nib's lesson).
    static let instructions = """
        You watch a coding agent working on a software project. Write one line that says what the agent \
        is doing at this moment, using only facts from the input. English, present tense, start with a verb, \
        at most 70 characters. No quotes, no file contents, no secrets, no long commands. \
        If the input is too vague to say more, name the kind of step (a shell command, a file edit, a search). \
        A latest message marked automatic came from the agent itself, not from the user.
        """

    func summarize(_ input: AgentSummaryInput) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), AppleIntelligenceBackend.isAvailable {
            let session = LanguageModelSession(instructions: Self.instructions)
            let options = GenerationOptions(temperature: 0.2, maximumResponseTokens: 60)
            let response = try await session.respond(to: input.promptText, generating: AgentActivityLine.self,
                                                     options: options)
            return response.content.line
        }
        #endif
        throw Unavailable()
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Generable
struct AgentActivityLine {
    @Guide(description: "One line, present tense, starts with a verb, at most 70 characters")
    var line: String
}
#endif
