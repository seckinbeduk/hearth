#if DEBUG
import Foundation

/// Debug builds only: `Hearth --agents-summary-check [fixtures dir]` replays made-up sessions (and the recorded
/// fixtures, if a folder is given) through the real Apple Intelligence summarizer, prints the lines and quits.
/// For judging the wording before a commit; never part of a release build.
enum AgentSummaryCheck {
    static let flag = "--agents-summary-check"

    @MainActor
    static func run(fixtures: URL?) async {
        let summarizer = AppleAgentSummarizer()
        print("Apple Intelligence available: \(AppleIntelligenceBackend.isAvailable)\n")
        for (name, events) in handMade() {
            var store = AgentSessionStore(), before = AgentSessionStore()
            events.forEach { store.apply($0) }
            events.dropLast().forEach { before.apply($0) }
            guard let session = store.sessions.values.first else { continue }
            // "Stopped: …" repeats the line written while the session was still working.
            var working: String?
            if session.stoppedEarly, let earlier = before.sessions.values.first {
                working = (try? await summarizer.summarize(AgentSummaryInput(session: earlier))).flatMap(AgentSummaryLine.tidy)
            }
            await report(name, AgentSummaryInput(session: session), summarizer, lastWorkingLine: working)
        }
        guard let fixtures else { return }
        for file in (try? FileManager.default.contentsOfDirectory(at: fixtures, includingPropertiesForKeys: nil)) ?? []
        where file.pathExtension == "jsonl" {
            var store = AgentSessionStore()
            let lines = ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n")
            for (number, line) in lines.enumerated() {
                guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let path = object["path"] as? String, let agent = AgentKind.allCases.first(where: { $0.path == path }),
                      let body = object["body"], let data = try? JSONSerialization.data(withJSONObject: body),
                      let event = AgentEventDecoder.decode(data, agent: agent, receivedAt: .now) else { continue }
                store.apply(event)
                // Summarize where the state settles: turn ends, permission, and every fifth event.
                let checkpoint: Bool = switch event.kind {
                case .turnEnded, .permissionRequested, .interrupted: true
                default: number % 5 == 4
                }
                if checkpoint, let session = store.sessions.values.first, session.phase != .ended {
                    await report("\(file.deletingPathExtension().lastPathComponent) #\(number + 1)",
                                 AgentSummaryInput(session: session), summarizer)
                }
            }
        }
    }

    @MainActor
    private static func report(_ name: String, _ input: AgentSummaryInput, _ summarizer: AppleAgentSummarizer,
                               lastWorkingLine: String? = nil) async {
        let started = ContinuousClock.now
        let line: String
        if let exact = AgentSummaryLine.deterministic(for: input, lastWorkingLine: lastWorkingLine) {
            line = exact + "   [code]"
        } else { do {
            let raw = try await summarizer.summarize(input)
            line = (AgentSummaryLine.line(fromModel: raw, for: input) ?? "(empty)") + (raw.count > AgentSummaryLine.maxLength ? "   [raw \(raw.count) chars]" : "")
        } catch {
            line = "FAILED (\(error)) → fallback: \(AgentSummaryLine.fallback(for: input) ?? "none")"
        } }
        let ms = (ContinuousClock.now - started).components.attoseconds / 1_000_000_000_000_000
            + (ContinuousClock.now - started).components.seconds * 1000
        print("[\(name)] \(AgentSummaryInput.describe(input.phase)), \(ms) ms\n  → \(line)\n")
    }

    // MARK: - Made-up sessions (no real names)

    private static func handMade() -> [(String, [AgentEvent])] {
        var clock = Date(timeIntervalSinceReferenceDate: 800_000_000)
        func e(_ kind: AgentEvent.Kind, agent: AgentKind = .claudeCode, prompt: String? = nil, tool: String? = nil,
               input: [String: Any]? = nil, message: String? = nil, sub: (String, String)? = nil) -> AgentEvent {
            clock.addTimeInterval(2)
            return AgentEvent(agent: agent, sessionID: "s", kind: kind, time: clock, cwd: "/Users/user/projects/uploader",
                              subagentID: sub?.0, subagentType: sub?.1, toolName: tool,
                              toolUseID: tool.map { _ in UUID().uuidString },
                              toolSummary: input.flatMap(AgentEventDecoder.summary(of:)), prompt: prompt, lastMessage: message)
        }
        let retry = "Add a retry with exponential backoff to the upload client, and cover it with tests."
        return [
            ("tests running", [
                e(.promptSubmitted, prompt: retry),
                e(.toolStarted, tool: "Read", input: ["file_path": "/Users/user/projects/uploader/Sources/Upload/UploadClient.swift"]),
                e(.toolStarted, tool: "Edit", input: ["file_path": "/Users/user/projects/uploader/Sources/Upload/UploadClient.swift"]),
                e(.toolStarted, tool: "Bash", input: ["command": "swift test --filter UploadClientTests"]),
            ]),
            ("permission to push", [
                e(.promptSubmitted, prompt: "Push the release branch and open a draft PR."),
                e(.toolStarted, tool: "Bash", input: ["command": "git push -u origin release/0.3"]),
                e(.permissionRequested, tool: "Bash", input: ["command": "git push -u origin release/0.3"]),
            ]),
            ("turn finished, asks to commit", [
                e(.promptSubmitted, prompt: retry),
                e(.toolStarted, tool: "Bash", input: ["command": "swift test"]),
                e(.turnEnded(backgroundTasks: []), message: "The retry is in place and all 14 tests pass. Should I commit it?"),
            ]),
            ("waiting on reviewer", [
                e(.promptSubmitted, prompt: "Have the reviewer check the diff before we commit."),
                e(.toolStarted, tool: "Agent", input: ["subagent_type": "reviewer", "prompt": "Review the uncommitted diff"]),
                e(.subagentStarted, sub: ("a1", "reviewer")),
                e(.turnEnded(backgroundTasks: [.init(id: "t1", type: "subagent", status: "running", agentType: "reviewer")]),
                  message: "The reviewer is looking at the diff; I'll report back when it's done."),
            ]),
            ("automatic prompt (reviewer result)", [
                e(.promptSubmitted, prompt: "<agent-message from=\"reviewer\">Verdict: OK with two corrections. 1. The backoff cap is never applied. 2. Add a test for cancellation.</agent-message>"),
                e(.toolStarted, tool: "Edit", input: ["file_path": "/Users/user/projects/uploader/Sources/Upload/Backoff.swift"]),
            ]),
            ("codex: CI failure", [
                e(.promptSubmitted, agent: .codex, prompt: "Why does the build fail on CI but not locally?"),
                e(.toolStarted, agent: .codex, tool: "Bash", input: ["command": "cat .github/workflows/ci.yml"]),
                e(.toolStarted, agent: .codex, tool: "Bash", input: ["command": "xcodebuild -scheme Uploader -destination 'platform=macOS' test"]),
            ]),
            ("docs edit", [
                e(.promptSubmitted, prompt: "Update the README's install section for the new Homebrew tap."),
                e(.toolStarted, tool: "Read", input: ["file_path": "/Users/user/projects/uploader/README.md"]),
                e(.toolStarted, tool: "Edit", input: ["file_path": "/Users/user/projects/uploader/README.md"]),
            ]),
            ("secret in a command", [
                e(.promptSubmitted, prompt: "Deploy the staging build."),
                e(.toolStarted, tool: "Bash", input: ["command": "API_TOKEN=sk-test-4f9a2b ./scripts/deploy.sh staging"]),
            ]),
            ("search", [
                e(.promptSubmitted, prompt: "Find every place we still use the old logger and list them."),
                e(.toolStarted, tool: "Grep", input: ["pattern": "LegacyLogger\\."]),
            ]),
            ("dev server left running", [
                e(.promptSubmitted, prompt: "Start the dev server so I can try the new settings page."),
                e(.toolStarted, tool: "Bash", input: ["command": "npm run dev"]),
                e(.turnEnded(backgroundTasks: [.init(id: "t1", type: "shell", status: "running", description: "npm run dev")]),
                  message: "The dev server is running at localhost:5173. Open /settings to try the new page."),
            ]),
            ("turn finished, Turkish message", [
                e(.promptSubmitted, prompt: "Reviewer düzeltmelerini işle ve commit'le."),
                e(.toolStarted, tool: "Bash", input: ["command": "git commit -m \"fix(agents): polish the rows\""]),
                e(.turnEnded(backgroundTasks: []), message: "Reviewer düzeltmelerini işledim, 119b635 olarak push ettim. 99 testin hepsi geçiyor."),
            ]),
            ("turn finished, Turkish question", [
                e(.promptSubmitted, prompt: "Paneldeki hatayı düzelt."),
                e(.turnEnded(backgroundTasks: []), message: "Düzeltmeyi hazırladım. Commit'leyip push edeyim mi?"),
            ]),
            ("just a prompt", [
                e(.promptSubmitted, prompt: "Plan the database migration that moves user settings into their own table."),
            ]),
            ("codex interrupted", [
                e(.promptSubmitted, agent: .codex, prompt: "Rename the Uploader module to Transfer everywhere."),
                e(.toolStarted, agent: .codex, tool: "Bash", input: ["command": "grep -rl Uploader Sources"]),
                e(.interrupted, agent: .codex),
            ]),
        ]
    }
}
#endif
