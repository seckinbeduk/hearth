import Foundation

/// Adds Hearth's hooks to an agent's settings file, and takes exactly those out again.
///
/// Hearth's entries are recognized by the URL in their command (`http://127.0.0.1:<port>/agents/<agent>`),
/// never by position. Connect replaces any older Hearth entries (so it's idempotent and fixes a port change);
/// Disconnect removes only them. Everything else in the file keeps its order and values. Only on explicit
/// user action, and a timestamped backup is written next to the file before every change.
enum AgentInstaller {
    enum InstallError: LocalizedError, Equatable {
        case invalidJSON(path: String)
        case notAnObject(path: String)
        /// `hooks`, or one of the events Hearth writes, isn't the shape the agent expects.
        case unexpectedHooks(path: String)

        var errorDescription: String? {
            switch self {
            case .invalidJSON(let path): "\(path) isn't valid JSON, so Hearth left it alone. Fix it, then try again."
            case .notAnObject(let path): "\(path) doesn't hold a JSON object, so Hearth left it alone."
            case .unexpectedHooks(let path): "The hooks in \(path) aren't in the expected format, so Hearth left the file alone."
            }
        }
    }

    /// Where the agent reads hooks from. Hearth runs as an app, without the shell's CODEX_HOME.
    static func settingsURL(for agent: AgentKind, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        switch agent {
        case .claudeCode: home.appendingPathComponent(".claude/settings.json")
        case .codex: home.appendingPathComponent(".codex/hooks.json")
        }
    }

    /// The events each agent reports. Claude Code: everything async. Codex: command hooks that return at once
    /// (`timeout` 1) and PermissionRequest async (proven not to decide anything, Step 2).
    static func events(for agent: AgentKind) -> [String] {
        switch agent {
        case .claudeCode:
            ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
             "PermissionRequest", "Stop", "StopFailure", "SubagentStart", "SubagentStop"]
        case .codex:
            ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest",
             "Stop", "Interrupt", "SubagentStart", "SubagentStop"]
        }
    }

    private static let toolEvents: Set<String> = ["PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest"]

    /// The forwarder: reads the payload into a variable (never a temp file), posts it from a background
    /// subshell with every stream detached, and exits 0 at once, so the agent never waits and sees no output.
    static func command(agent: AgentKind, port: Int, token: String) -> String {
        "P=$(cat); ( printf '%s' \"$P\" | curl -s -o /dev/null -m 1 -H 'Expect:' "
            + "-H 'Content-Type: application/json' -H 'X-Hearth-Token: \(token)' --data-binary @- "
            + "\(url(agent: agent, port: port)) ) </dev/null >/dev/null 2>&1 & exit 0"
    }

    static func url(agent: AgentKind, port: Int) -> String { "http://127.0.0.1:\(port)\(agent.path)" }

    // MARK: - Pure edits (tested on fixture files)

    /// The settings with Hearth's hooks for `port` and `token`, replacing any older Hearth entries.
    static func connect(_ original: Data?, agent: AgentKind, port: Int, token: String, path: String) throws -> Data {
        var root = try removingHearth(from: try parse(original, path: path), agent: agent)
        var hooks = root["hooks"] ?? .object([])
        // Never replace a value we don't understand: refuse instead.
        guard hooks.objectPairs != nil else { throw InstallError.unexpectedHooks(path: path) }
        for event in events(for: agent) where hooks[event] != nil && hooks[event]?.arrayValue == nil {
            throw InstallError.unexpectedHooks(path: path)
        }
        for event in events(for: agent) {
            var handler: [(key: String, value: OrderedJSON)] = [
                ("type", .string("command")), ("command", .string(command(agent: agent, port: port, token: token)))]
            if agent == .claudeCode || event == "PermissionRequest" {
                handler.append(("async", .bool(true)))
            } else {
                handler.append(("timeout", .number("1")))
            }
            var group: [(key: String, value: OrderedJSON)] = []
            if toolEvents.contains(event) { group.append(("matcher", .string("*"))) }
            group.append(("hooks", .array([.object(handler)])))
            var groups = hooks[event]?.arrayValue ?? []
            groups.append(.object(group))
            hooks.set(event, .array(groups))
        }
        root.set("hooks", hooks)
        return output(root, like: original)
    }

    /// The settings without Hearth's hooks; `nil` when the file should be deleted (it held nothing else and
    /// didn't exist before Connect, which only happens for Codex's hooks.json).
    static func disconnect(_ original: Data?, agent: AgentKind, path: String) throws -> Data? {
        guard let original else { return nil }
        let root = try removingHearth(from: try parse(original, path: path), agent: agent)
        if agent == .codex, root == .object([("hooks", .object([]))]) { return nil }
        return output(root, like: original)
    }

    enum Status: Equatable, Sendable {
        case notConnected
        case connected
        /// Hearth's hooks are there but point at another port or carry an old token: offer "Fix".
        case needsFix(port: Int?)
    }

    /// Without a port (Hearth's server isn't up yet), Hearth's hooks being there counts as connected.
    static func status(_ data: Data?, agent: AgentKind, port: Int?, token: String) -> Status {
        guard let data, let root = try? OrderedJSON.parse(data) else { return .notConnected }
        let commands = hearthCommands(in: root, agent: agent)
        if commands.isEmpty { return .notConnected }
        guard let port else { return .connected }
        let expected = command(agent: agent, port: port, token: token)
        let complete = Set(events(for: agent)).isSubset(of: Set(commands.map(\.event)))
        if complete, commands.allSatisfy({ $0.command == expected }) { return .connected }
        return .needsFix(port: commands.lazy.compactMap { portIn($0.command, agent: agent) }.first)
    }

    // MARK: - Files

    /// Writes `data` (or deletes the file for `nil`) after a timestamped backup, keeping the file's mode.
    static func write(_ data: Data?, to link: URL, now: Date = .now) throws {
        // A settings file is often a symlink into a dotfiles repo: edit the file it points to, keep the link.
        let url = link.resolvingSymlinksInPath()
        let fm = FileManager.default
        let existed = fm.fileExists(atPath: url.path)
        let mode = (try? fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? 0o600
        if existed { try backUp(url, now: now) }
        guard let data else {
            if existed { try fm.removeItem(at: url) }
            return
        }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    static func backUp(_ url: URL, now: Date) throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        var backup = url.appendingPathExtension("hearth-backup-\(formatter.string(from: now))")
        var counter = 2
        while FileManager.default.fileExists(atPath: backup.path) {
            backup = url.appendingPathExtension("hearth-backup-\(formatter.string(from: now))-\(counter)")
            counter += 1
        }
        try FileManager.default.copyItem(at: url, to: backup)
    }

    /// Whether Codex's config.toml defines hooks of its own (`[hooks.<Event>]`, `[[hooks.<Event>]]`,
    /// `hooks = …`). Codex merges those with hooks.json and warns at startup. Its own trust records
    /// (`[hooks.state…]`) don't count.
    static func codexConfigHasHooks(_ toml: String) -> Bool {
        toml.split(separator: "\n").contains { line in
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.wholeMatch(of: /hooks\s*=.*/) != nil { return true }
            guard let match = text.wholeMatch(of: /\[\[?\s*hooks(\.[^\]]*)?\s*\]\]?.*/) else { return false }
            let rest = match.output.1.map(String.init) ?? ""
            return !(rest == ".state" || rest.hasPrefix(".state.") || rest.hasPrefix(".state "))
        }
    }

    // MARK: - Helpers

    private static func parse(_ data: Data?, path: String) throws -> OrderedJSON {
        guard let data, !data.allSatisfy({ [0x20, 0x0A, 0x0D, 0x09].contains($0) }) else { return .object([]) }
        guard let root = try? OrderedJSON.parse(data) else { throw InstallError.invalidJSON(path: path) }
        guard root.objectPairs != nil else { throw InstallError.notAnObject(path: path) }
        return root
    }

    /// Removes every handler whose command posts to Hearth's endpoint for this agent; then groups and event
    /// lists that only held Hearth's handlers. The `hooks` object itself stays, even when it ends up empty.
    private static func removingHearth(from root: OrderedJSON, agent: AgentKind) throws -> OrderedJSON {
        guard var hooks = root["hooks"], let events = hooks.objectPairs else { return root }
        for (event, value) in events {
            guard let groups = value.arrayValue else { continue }
            var kept: [OrderedJSON] = []
            var changed = false
            for group in groups {
                guard let handlers = group["hooks"]?.arrayValue else { kept.append(group); continue }
                let others = handlers.filter { !isHearth($0, agent: agent) }
                if others.count == handlers.count { kept.append(group); continue }
                changed = true
                if others.isEmpty { continue }
                var trimmed = group
                trimmed.set("hooks", .array(others))
                kept.append(trimmed)
            }
            guard changed else { continue }
            hooks.set(event, kept.isEmpty ? nil : .array(kept))
        }
        var result = root
        result.set("hooks", hooks)
        return result
    }

    private static func isHearth(_ handler: OrderedJSON, agent: AgentKind) -> Bool {
        guard let command = handler["command"]?.stringValue else { return false }
        return portIn(command, agent: agent) != nil
    }

    private static func hearthCommands(in root: OrderedJSON, agent: AgentKind) -> [(event: String, command: String)] {
        guard let events = root["hooks"]?.objectPairs else { return [] }
        return events.flatMap { event, groups in
            (groups.arrayValue ?? []).flatMap { group in
                (group["hooks"]?.arrayValue ?? []).compactMap { handler -> (event: String, command: String)? in
                    guard isHearth(handler, agent: agent), let command = handler["command"]?.stringValue else { return nil }
                    return (event, command)
                }
            }
        }
    }

    /// The port in `http://127.0.0.1:<port>/agents/<agent>` inside a command, if it's Hearth's.
    static func portIn(_ command: String, agent: AgentKind) -> Int? {
        let pattern = "http://127\\.0\\.0\\.1:([0-9]{1,5})" + NSRegularExpression.escapedPattern(for: agent.path) + "(?![A-Za-z0-9_-])"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)),
              let range = Range(match.range(at: 1), in: command) else { return nil }
        return Int(command[range])
    }

    /// Prints like Claude Code does and keeps the original's trailing newline (or its absence).
    private static func output(_ root: OrderedJSON, like original: Data?) -> Data {
        let newline = original.map { $0.last == 0x0A } ?? true
        return Data((root.printed() + (newline ? "\n" : "")).utf8)
    }
}
