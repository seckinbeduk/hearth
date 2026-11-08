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
    /// The tool waiting for permission (main agent), or the subagent that asks.
    var pendingTool: AgentSession.Tool?
    /// The agent's own description of the pending call, preferred for the permission line.
    var pendingDescription: String?
    var askingSubagent: String?
    var stoppedEarly = false

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
        self.init(agent: session.agent, project: session.project, phase: session.effectivePhase,
                  prompt: session.lastPrompt, promptIsAutomatic: session.lastPrompt.map(Self.isAutomatic) ?? false,
                  tools: session.recentTools, lastMessage: session.lastMessage, subagents: session.subagents.map(\.type))
        if session.phase == .permission {
            pendingTool = session.permissionTool.map { AgentSession.Tool(name: $0, summary: session.permissionHint) }
            pendingDescription = session.permissionDescription
        } else {
            askingSubagent = session.subagents.first { $0.phase == .permission }?.type
        }
        stoppedEarly = session.stoppedEarly
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
                               "State: \(Self.describe(phase))", "Write: \(task)"]
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

    /// For "your turn", code picks the start from the last message (a question → "Asks whether", else "Done:")
    /// and the model only writes the rest: a small model doesn't keep a prefix reliably.
    var turnPrefix: String? {
        guard phase == .yourTurn, !stoppedEarly else { return nil }
        guard let question = Self.closingQuestion(lastMessage ?? "") else { return "Done:" }
        let first = question.split(separator: " ").first.map { $0.lowercased() } ?? ""
        return ["which", "what", "how", "where", "when", "who", "why"].contains(first) ? "Asks" : "Asks whether"
    }

    /// The question the message ends with, if any. A trailing list of options doesn't count as the end
    /// ("Which do you prefer?\n1. …\n2. …"), and a "?" inside a URL isn't a question mark.
    static func closingQuestion(_ message: String) -> String? {
        let lines = message.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let isOption = { (line: String) in line.wholeMatch(of: /(?:[-*•]|\d+[.)])\s+.*/) != nil }
        guard let last = lines.last(where: { !isOption($0) }) else { return nil }
        let sentences = last.split(whereSeparator: { ".!".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let sentence = sentences.last(where: { !$0.isEmpty }),
              sentence.firstMatch(of: /\?(?:[\s*)"']|$)/) != nil else { return nil }
        return sentence
    }

    /// What the model should write (only for the states it writes).
    var task: String {
        switch turnPrefix {
        case "Asks whether":
            "only the rest of the sentence \"The agent asks whether …\": what it asks the user, a few words "
                + "in English"
        case "Asks":
            "only the rest of the sentence \"The agent asks …\", starting with which, what, how, where, when, "
                + "who or why: what it asks the user, a few words"
        case "Done:":
            "only what the agent finished or found, as a short phrase, judging by its last message. "
                + "In English; translate if the message isn't English"
        default:
            "what the agent is doing right now, starting with a verb in -ing form (Editing, Running, Reading, "
                + "Writing, Searching, Planning, Fixing). Describe the work; don't repeat the user's request"
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

    /// The model's text made into the line: tidied, with the "your turn" start added by code.
    /// `lastWorkingLine` replaces a rejected "your turn" line: what the session was last seen doing beats a
    /// generic text.
    static func line(fromModel raw: String, for input: AgentSummaryInput, lastWorkingLine: String? = nil) -> String? {
        guard var text = tidy(raw) else { return nil }
        // Never a quote and never another language: the line must be the model's own English.
        // Copies only matter from text that isn't English (an English echo of a feature name is fine).
        let names = [input.prompt, input.lastMessage] + input.tools.map(\.summary) + [input.pendingTool?.summary]
        let foreign = [input.lastMessage, input.prompt].filter { !isEnglishLooking($0 ?? "") }
        if copies(text, from: foreign) || !isEnglishLooking(text, allowing: names.compactMap { $0 }) {
            // A finished turn: what it was last doing says more than "turn finished". A question stays a question.
            if input.turnPrefix == "Done:", let lastWorkingLine { return lastWorkingLine }
            switch input.turnPrefix {
            case "Asks whether", "Asks": return "Asks you a question"
            case "Done:": return "Done: turn finished"
            default: return fallback(for: input)
            }
        }
        guard let prefix = input.turnPrefix else {
            // A working line describes the work in -ing form; one that echoes the request falls back to the tool.
            let first = text.split(separator: " ").first
                .map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) } ?? ""
            if input.phase == .running, !first.hasSuffix("ing"), let fallback = fallback(for: input) { return fallback }
            return text
        }
        for start in ["The agent asks whether", "The agent asks", "Asks whether", "Asks", "Done:", "Done", "Reports"]
        where text.lowercased().hasPrefix(start.lowercased()) {
            text = String(text.dropFirst(start.count)).trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
            break
        }
        if prefix == "Asks whether" {
            // The model often quotes the question itself: "Should I commit…" → "to commit…".
            for (question, rest) in [("should i ", "to "), ("shall i ", "to "), ("do you want me to ", "to "),
                                     ("would you like me to ", "to "), ("can i ", "it can "), ("may i ", "it may ")]
            where text.lowercased().hasPrefix(question) {
                text = rest + text.dropFirst(question.count)
                break
            }
        }
        guard let first = text.first else { return nil }
        if prefix.hasPrefix("Asks") { text = first.lowercased() + text.dropFirst() }
        if text.hasSuffix("?") { text.removeLast() }
        return tidy("\(prefix) \(text)")
    }

    /// Five or more words in a row taken from the agent's message or the prompt.
    static func copies(_ line: String, from sources: [String?]) -> Bool {
        let words = { (text: String) in
            text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        }
        let lineWords = words(line)
        guard lineWords.count >= 5 else { return false }
        let runs = Set((0...(lineWords.count - 5)).map { lineWords[$0..<$0 + 5].joined(separator: " ") })
        return sources.compactMap { $0 }.contains { source in
            let sourceWords = words(source)
            guard sourceWords.count >= 5 else { return false }
            return (0...(sourceWords.count - 5)).contains { runs.contains(sourceWords[$0..<$0 + 5].joined(separator: " ")) }
        }
    }

    /// Letters are plain ASCII (file names aside, an English line has no ç, ğ, ş, ü…).
    /// Words with non-ASCII letters that also appear in a tool hint count as names ("Çeviri.swift") and pass.
    static func isEnglishLooking(_ line: String, allowing names: [String] = []) -> Bool {
        let nameWords = Set(names.flatMap { $0.split(whereSeparator: \.isWhitespace).map(String.init) })
        return !line.split(whereSeparator: \.isWhitespace).contains { word in
            word.unicodeScalars.contains { $0.properties.isAlphabetic && !$0.isASCII }
                && !nameWords.contains { $0.contains(word.trimmingCharacters(in: .punctuationCharacters)) }
        }
    }

    /// Lines code can write exactly, without the model: permission (what the agent wants to do), a stopped turn,
    /// waiting on a subagent. `lastWorkingLine` is the session's latest summary while it was working.
    static func deterministic(for input: AgentSummaryInput, lastWorkingLine: String?) -> String? {
        switch input.phase {
        case .permission:
            if let who = input.askingSubagent { return tidy("\(AgentSummaryInput.clean(who, limit: 40)) wants permission") }
            if let description = input.pendingDescription {
                return tidy("Wants to: " + AgentSummaryInput.clean(description, limit: 60))
            }
            guard let tool = input.pendingTool else { return "Wants permission" }
            let hint = tool.summary.map { shortCommand(AgentSummaryInput.clean($0, limit: 120), tool: tool.name) }
            let verb: String? = switch tool.name {
            case "Bash", "shell", "exec_command", "local_shell": "run"
            case "Edit", "Write", "MultiEdit", "NotebookEdit", "apply_patch": "edit"
            case "WebFetch": "fetch"
            default: nil
            }
            if let verb, let hint { return tidy("Wants to \(verb) \(hint)") }
            return tidy("Wants to use \(tool.name)")
        case .yourTurn where input.stoppedEarly:
            let last = lastWorkingLine ?? fallback(for: input)
            return tidy("Stopped" + (last.map { ": \($0)" } ?? ""))
        case .waitingOn(let task):
            return tidy("Waiting for \(AgentSummaryInput.clean(task, limit: 50))")
        default:
            return nil
        }
    }

    /// A command shown as its first word, subcommand and target, not as a whole script: "git push … main",
    /// "rm build", "npm test". Leading `cd …` and bare assignments are skipped, redirections and quoted
    /// arguments dropped; anything that still isn't a plain command is shown cut as before. Non-shell hints
    /// pass through.
    static func shortCommand(_ hint: String, tool: String) -> String {
        guard ["Bash", "shell", "exec_command", "local_shell"].contains(tool) else { return hint }
        let asBefore = String(hint.prefix(50))
        let segments = hint.split(whereSeparator: { ";&|\n".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let isSetup = { (segment: String) -> Bool in
            let words = segment.split(separator: " ")
            return words.first == "cd" || (words.count == 1 && segment.contains("="))
        }
        guard var segment = segments.first(where: { !isSetup($0) }) else { return asBefore }
        segment = segment.replacing(/"[^"]*"|'[^']*'/, with: " ")           // quoted arguments
        segment = segment.replacing(/\s\d*[<>]+&?\S*/, with: " ")         // redirections
        guard segment.firstMatch(of: /[$()`<>"']/) == nil else { return asBefore }
        var words = segment.split(separator: " ").map(String.init).filter { !$0.contains("=") }
        // Flags that take the next word as their value (-m message, -C dir): drop both.
        let takesValue: Set<String> = ["-m", "-C", "-c", "-o", "-e", "-F", "-b"]
        var index = 0
        while index < words.count {
            if takesValue.contains(words[index]) {
                words.removeSubrange(index..<min(index + 2, words.count))
            } else if words[index].hasPrefix("-") {
                words.remove(at: index)
            } else {
                index += 1
            }
        }
        guard let command = words.first else { return asBefore }
        var parts = [command]
        if words.count > 1, words[1].allSatisfy({ $0.isLetter }) { parts.append(words[1]) }
        if let target = words.dropFirst(parts.count).last { parts.append(parts.count < words.count - 1 ? "… \(target)" : target) }
        return parts.joined(separator: " ")
    }

    /// Used when Apple Intelligence is unavailable or fails: the last tool and its hint.
    static func fallback(for input: AgentSummaryInput) -> String? {
        guard let tool = input.tools.last else { return nil }
        var hint = tool.summary.map { shortCommand(AgentSummaryInput.clean($0, limit: 120), tool: tool.name) }
            .map { String($0.prefix(50)) }
        if ["Grep", "Glob"].contains(tool.name) {
            hint = hint.map { $0.replacingOccurrences(of: "\\", with: "").trimmingCharacters(in: .punctuationCharacters) }
        }
        let verb: String
        switch tool.name {
        case "Bash", "shell", "exec_command", "local_shell": verb = "Running"
        case "Read", "LS": verb = "Reading"
        case "Grep", "Glob": verb = "Searching"
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
        You watch a coding agent working on a software project. Write one line about it, using only facts \
        from the input, in the form the "Write" line asks for. Always English: translate when the input is \
        in another language. At most 70 characters. \
        No quotes, no file contents, no secrets, no long commands. If the input is too vague to say more, \
        name the kind of step (a shell command, a file edit, a search). \
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
    @Guide(description: "One line in the form the prompt asks for, at most 70 characters")
    var line: String
}
#endif
