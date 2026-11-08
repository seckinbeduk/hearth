import Testing
import Foundation
@testable import Hearth

private let token = String(repeating: "ab", count: 32)
private let path = "~/.claude/settings.json"

/// A settings.json like Claude Code writes it: two-space JSON, trailing newline.
private let plainSettings = """
{
  "theme": "dark",
  "agentPushNotifEnabled": true,
  "hooks": {}
}

"""

/// The user's own hooks, including one group that will end up sharing an event with Hearth's.
private let settingsWithHooks = """
{
  "model": "opus",
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "~/bin/check-command.sh",
            "timeout": 5
          }
        ]
      }
    ],
    "Notification": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "say \\"done\\""
          }
        ]
      }
    ]
  },
  "permissions": {
    "allow": [
      "Bash(git status)"
    ]
  },
  "cleanupPeriodDays": 30.0
}
"""

private func text(_ data: Data?) -> String? { data.map { String(decoding: $0, as: UTF8.self) } }

private func hearthHandlers(_ data: Data, agent: AgentKind) throws -> [(event: String, handler: OrderedJSON)] {
    let root = try OrderedJSON.parse(data)
    return (root["hooks"]?.objectPairs ?? []).flatMap { event, groups in
        (groups.arrayValue ?? []).flatMap { ($0["hooks"]?.arrayValue ?? []) }
            .filter { AgentInstaller.portIn($0["command"]?.stringValue ?? "", agent: agent) != nil }
            .map { (event, $0) }
    }
}

struct AgentInstallerTests {
    @Test func connectThenDisconnectRestoresTheFileByteForByte() throws {
        for original in [plainSettings, settingsWithHooks] {
            let data = Data(original.utf8)
            let connected = try AgentInstaller.connect(data, agent: .claudeCode, port: 8800, token: token, path: path)
            #expect(try hearthHandlers(connected, agent: .claudeCode).count == AgentInstaller.events(for: .claudeCode).count)
            let restored = try AgentInstaller.disconnect(connected, agent: .claudeCode, path: path)
            #expect(text(restored) == original)
        }
    }

    @Test func usersOwnHooksAndKeysStayInPlace() throws {
        let connected = try AgentInstaller.connect(Data(settingsWithHooks.utf8), agent: .claudeCode,
                                                   port: 8800, token: token, path: path)
        let root = try OrderedJSON.parse(connected)
        #expect(root.objectPairs?.map(\.key) == ["model", "hooks", "permissions", "cleanupPeriodDays"])
        #expect(root["cleanupPeriodDays"] == .number("30.0"))
        let preToolUse = try #require(root["hooks"]?["PreToolUse"]?.arrayValue)
        #expect(preToolUse.count == 2)
        #expect(preToolUse[0]["matcher"] == .string("Bash"))     // the user's group first, untouched
        #expect(preToolUse[1]["matcher"] == .string("*"))
        // Hearth doesn't add Notification; the user's stays alone.
        #expect(root["hooks"]?["Notification"]?.arrayValue?.count == 1)
    }

    @Test func claudeHooksAreAsyncAndCodexHooksReturnAtOnce() throws {
        let claude = try AgentInstaller.connect(nil, agent: .claudeCode, port: 8800, token: token, path: path)
        for (_, handler) in try hearthHandlers(claude, agent: .claudeCode) {
            #expect(handler["async"] == .bool(true))
            #expect(handler["timeout"] == nil)
            #expect(handler["onFailure"] == nil)
        }
        let codex = try AgentInstaller.connect(nil, agent: .codex, port: 8800, token: token, path: path)
        for (event, handler) in try hearthHandlers(codex, agent: .codex) {
            if event == "PermissionRequest" {
                #expect(handler["async"] == .bool(true))
            } else {
                #expect(handler["timeout"] == .number("1"))
                #expect(handler["async"] == nil)
            }
        }
        #expect(Set(try hearthHandlers(codex, agent: .codex).map(\.event)) == Set(AgentInstaller.events(for: .codex)))
    }

    @Test func commandIsTheDetachedForwarder() {
        let command = AgentInstaller.command(agent: .codex, port: 8801, token: token)
        #expect(command.hasPrefix("P=$(cat); ( printf '%s' \"$P\" | curl -s -o /dev/null -m 1 -H 'Expect:' "))
        #expect(command.contains("-H 'X-Hearth-Token: \(token)'"))
        #expect(command.hasSuffix("http://127.0.0.1:8801/agents/codex ) </dev/null >/dev/null 2>&1 & exit 0"))
        #expect(!command.contains("perl"))
    }

    @Test func connectTwiceAddsNothing() throws {
        let once = try AgentInstaller.connect(Data(settingsWithHooks.utf8), agent: .claudeCode, port: 8800, token: token, path: path)
        let twice = try AgentInstaller.connect(once, agent: .claudeCode, port: 8800, token: token, path: path)
        #expect(once == twice)
    }

    @Test func portChangeRewritesOnlyHearthsEntries() throws {
        let old = try AgentInstaller.connect(Data(settingsWithHooks.utf8), agent: .claudeCode, port: 8800, token: token, path: path)
        #expect(AgentInstaller.status(old, agent: .claudeCode, port: 8800, token: token) == .connected)
        #expect(AgentInstaller.status(old, agent: .claudeCode, port: 8801, token: token) == .needsFix(port: 8800))
        #expect(AgentInstaller.status(old, agent: .claudeCode, port: 8800, token: "other") == .needsFix(port: 8800))

        let fixed = try AgentInstaller.connect(old, agent: .claudeCode, port: 8801, token: token, path: path)
        #expect(AgentInstaller.status(fixed, agent: .claudeCode, port: 8801, token: token) == .connected)
        let ports = try hearthHandlers(fixed, agent: .claudeCode)
            .compactMap { AgentInstaller.portIn($0.handler["command"]?.stringValue ?? "", agent: .claudeCode) }
        #expect(Set(ports) == [8801])
        #expect(text(try AgentInstaller.disconnect(fixed, agent: .claudeCode, path: path)) == settingsWithHooks)
    }

    @Test func disconnectKeepsUserHandlersSharingAGroupWithHearth() throws {
        let shared = """
        {
          "hooks": {
            "Stop": [
              {
                "hooks": [
                  {
                    "type": "command",
                    "command": "~/bin/mine.sh"
                  },
                  {
                    "type": "command",
                    "command": "\(AgentInstaller.command(agent: .claudeCode, port: 8800, token: token).replacingOccurrences(of: "\"", with: "\\\""))",
                    "async": true
                  }
                ]
              }
            ]
          }
        }

        """
        let cleaned = try #require(try AgentInstaller.disconnect(Data(shared.utf8), agent: .claudeCode, path: path))
        let root = try OrderedJSON.parse(cleaned)
        let handlers = try #require(root["hooks"]?["Stop"]?.arrayValue?.first?["hooks"]?.arrayValue)
        #expect(handlers.count == 1)
        #expect(handlers.first?["command"] == .string("~/bin/mine.sh"))
    }

    @Test func emptyAndMissingFiles() throws {
        let fromEmpty = try AgentInstaller.connect(Data("  \n".utf8), agent: .claudeCode, port: 8800, token: token, path: path)
        #expect(text(try AgentInstaller.disconnect(fromEmpty, agent: .claudeCode, path: path)) == "{\n  \"hooks\": {}\n}\n")

        // Codex's hooks.json usually doesn't exist: Connect creates it, Disconnect deletes it again.
        let created = try AgentInstaller.connect(nil, agent: .codex, port: 8800, token: token, path: path)
        #expect(try AgentInstaller.disconnect(created, agent: .codex, path: path) == nil)
        #expect(try AgentInstaller.disconnect(nil, agent: .codex, path: path) == nil)
    }

    @Test func invalidFilesAreLeftAlone() {
        #expect(throws: AgentInstaller.InstallError.invalidJSON(path: path)) {
            try AgentInstaller.connect(Data("{\"hooks\": ".utf8), agent: .claudeCode, port: 8800, token: token, path: path)
        }
        #expect(throws: AgentInstaller.InstallError.notAnObject(path: path)) {
            try AgentInstaller.connect(Data("[]".utf8), agent: .claudeCode, port: 8800, token: token, path: path)
        }
        #expect(throws: AgentInstaller.InstallError.invalidJSON(path: path)) {
            try AgentInstaller.disconnect(Data("{,}".utf8), agent: .claudeCode, path: path)
        }
        #expect(AgentInstaller.status(Data("nope".utf8), agent: .claudeCode, port: 8800, token: token) == .notConnected)
        // Shapes Hearth doesn't understand are refused, never replaced.
        for odd in [#"{"hooks": []}"#, #"{"hooks": null}"#, #"{"hooks": {"Stop": {}}}"#] {
            #expect(throws: AgentInstaller.InstallError.unexpectedHooks(path: path)) {
                try AgentInstaller.connect(Data(odd.utf8), agent: .claudeCode, port: 8800, token: token, path: path)
            }
        }
        #expect(throws: AgentInstaller.InstallError.invalidJSON(path: path)) {
            try AgentInstaller.connect(Data(#"{"cleanupPeriodDays": 01}"#.utf8), agent: .claudeCode, port: 8800, token: token, path: path)
        }
    }

    @Test func spotsHooksInCodexConfig() {
        let trustOnly = """
        model = "x"
        [hooks.state]

        [hooks.state."/Users/user/.codex/hooks.json:stop:0:0"]
        trusted_hash = "abc"
        """
        #expect(!AgentInstaller.codexConfigHasHooks(trustOnly))
        #expect(AgentInstaller.codexConfigHasHooks(trustOnly + "\n[[hooks.PreToolUse]]\nmatcher = \"*\""))
        #expect(AgentInstaller.codexConfigHasHooks("[hooks.Stop]\n"))
        #expect(AgentInstaller.codexConfigHasHooks("hooks = { Stop = [] }"))
        #expect(!AgentInstaller.codexConfigHasHooks("[features]\ncodex_hooks = true"))
    }

    @Test func writeFollowsASymlinkedSettingsFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hearth-symlink-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.appendingPathComponent("dotfiles-settings.json")
        let link = dir.appendingPathComponent("settings.json")
        try Data(plainSettings.utf8).write(to: target)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        try fm.createSymbolicLink(at: link, withDestinationURL: target)

        try AgentInstaller.write(Data("{}\n".utf8), to: link, now: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(try fm.destinationOfSymbolicLink(atPath: link.path) == target.path)
        #expect(text(try Data(contentsOf: target)) == "{}\n")
        #expect(try fm.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int == 0o600)
        let backup = try #require(try fm.contentsOfDirectory(atPath: dir.path).first { $0.contains("hearth-backup") })
        #expect(try fm.attributesOfItem(atPath: dir.appendingPathComponent(backup).path)[.type] as? FileAttributeType == .typeRegular)
        #expect(text(try Data(contentsOf: dir.appendingPathComponent(backup))) == plainSettings)
    }

    @Test func recognizesOnlyItsOwnAgentsURL() {
        #expect(AgentInstaller.portIn("curl http://127.0.0.1:8805/agents/codex )", agent: .codex) == 8805)
        #expect(AgentInstaller.portIn("curl http://127.0.0.1:8805/agents/codex )", agent: .claudeCode) == nil)
        #expect(AgentInstaller.portIn("curl http://127.0.0.1:8805/agents/codex-other", agent: .codex) == nil)
        #expect(AgentInstaller.portIn("curl http://localhost:8805/agents/codex", agent: .codex) == nil)
    }

    @Test func writeBacksUpKeepsModeAndDeletes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hearth-installer-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("settings.json")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(plainSettings.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try AgentInstaller.write(Data("{}\n".utf8), to: url, now: now)
        try AgentInstaller.write(Data("{}\n".utf8), to: url, now: now)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(files.count == 3)
        #expect(files.filter { $0.hasPrefix("settings.json.hearth-backup-") }.count == 2)
        let first = try #require(files.first { $0.hasPrefix("settings.json.hearth-backup-") && !$0.hasSuffix("-2") })
        #expect(text(try Data(contentsOf: dir.appendingPathComponent(first))) == plainSettings)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o644)

        try AgentInstaller.write(nil, to: url, now: now)
        #expect(!FileManager.default.fileExists(atPath: url.path))

        // A new file gets 0600.
        try AgentInstaller.write(Data("{}\n".utf8), to: url, now: now)
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int == 0o600)
    }
}

struct OrderedJSONTests {
    @Test func roundTripsClaudeCodeFormatting() throws {
        for original in [plainSettings, settingsWithHooks, "{}", "[]", "{\n  \"a\": [],\n  \"b\": {}\n}"] {
            let parsed = try OrderedJSON.parse(Data(original.utf8))
            #expect(parsed.printed() == original.trimmingCharacters(in: .newlines))
        }
    }

    @Test func parsesEscapesAndNumbers() throws {
        let json = #"{"s":"a\"b\\c\ndé😀/","n":-1.5e3,"z":0,"t":true,"f":false,"x":null}"#
        let value = try OrderedJSON.parse(Data(json.utf8))
        #expect(value["s"] == .string("a\"b\\c\ndé😀/"))
        #expect(value["n"] == .number("-1.5e3"))
        #expect(value["x"] == .null)
        #expect(try OrderedJSON.parse(Data(value.printed().utf8)) == value)
        #expect(OrderedJSON.quoted("tab\there\u{01}") == #""tab\there\u0001""#)
    }

    @Test func rejectsBrokenJSON() {
        for broken in ["", "{", "{\"a\":}", "[1,]", "{\"a\":1}x", "\"\u{01}\"", "01x", "tru", "+1", "01", ".5", "1.", "1e"] {
            #expect(throws: OrderedJSON.ParseError.self) { try OrderedJSON.parse(Data(broken.utf8)) }
        }
    }
}
