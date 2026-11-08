import Testing
import Foundation
@testable import Hearth

/// Records every input and answers with a line, or fails.
private final class FakeSummarizer: AgentSummarizer, @unchecked Sendable {
    private let lock = NSLock()
    private var inputs: [AgentSummaryInput] = []
    var answer: String? = "Running the uploader tests"

    func summarize(_ input: AgentSummaryInput) async throws -> String {
        let answer = lock.withLock { inputs.append(input); return self.answer }
        guard let answer else { throw CancellationError() }
        return answer
    }

    var calls: [AgentSummaryInput] { lock.lock(); defer { lock.unlock() }; return inputs }
}

/// Never answers until cancelled, like a long on-device call.
private final class HangingSummarizer: AgentSummarizer, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }

    func summarize(_ input: AgentSummaryInput) async throws -> String {
        lock.withLock { count += 1 }
        try await Task.sleep(for: .seconds(3600))
        return "never"
    }
}

@MainActor
private final class Clock {
    var now = Date(timeIntervalSinceReferenceDate: 0)
    func advance(_ seconds: TimeInterval) { now.addTimeInterval(seconds) }
}

@MainActor
private func makeModel(_ fake: FakeSummarizer, _ clock: Clock) -> AgentsModel {
    let settings = AgentSettings(defaults: nil)
    settings.isEnabled = true
    return AgentsModel(settings: settings, summarizer: fake, now: { clock.now })
}

@MainActor
private func settle(_ model: AgentsModel) async {
    for _ in 0..<50 {
        guard let work = model.summaryWork else { return }
        await work.value
    }
}

@MainActor
private func event(_ kind: AgentEvent.Kind, at time: Date, tool: String? = nil, summary: String? = nil,
                   prompt: String? = nil) -> AgentEvent {
    AgentEvent(agent: .claudeCode, sessionID: "s", kind: kind, time: time, cwd: "/tmp/uploader",
               toolName: tool, toolUseID: tool.map { _ in UUID().uuidString }, toolSummary: summary, prompt: prompt)
}

@MainActor
struct AgentSummarySchedulingTests {
    private let key = AgentSession.Key(agent: .claudeCode, sessionID: "s")

    @Test func summarizesOnStateChangeAndThrottlesWhileRunning() async {
        let fake = FakeSummarizer(), clock = Clock()
        let model = makeModel(fake, clock)
        model.apply(event(.promptSubmitted, at: clock.now, prompt: "Add a retry"))
        await settle(model)
        #expect(fake.calls.count == 1)
        #expect(model.summaries[key] == "Running the uploader tests")

        // More activity within 20 s: no new call.
        clock.advance(5)
        model.apply(event(.toolStarted, at: clock.now, tool: "Bash", summary: "swift test"))
        await settle(model)
        #expect(fake.calls.count == 1)

        // After 20 s with new activity: one more.
        clock.advance(16)
        model.apply(event(.toolFinished, at: clock.now, tool: "Bash"))
        await settle(model)
        #expect(fake.calls.count == 2)
        #expect(fake.calls.last?.tools.map(\.name) == ["Bash"])

        // A state change is summarized at once.
        clock.advance(1)
        model.apply(event(.turnEnded(backgroundTasks: []), at: clock.now))
        await settle(model)
        #expect(fake.calls.count == 3)
        #expect(fake.calls.last?.phase == .yourTurn)
    }

    @Test func neverForEndedStaleOrOff() async {
        let fake = FakeSummarizer(), clock = Clock()
        let model = makeModel(fake, clock)
        model.apply(event(.sessionStarted, at: clock.now))       // idle, nothing to say yet
        await settle(model)
        #expect(fake.calls.isEmpty)

        model.apply(event(.promptSubmitted, at: clock.now, prompt: "Plan the migration"))
        await settle(model)
        model.apply(event(.sessionEnded, at: clock.now))
        await settle(model)
        #expect(fake.calls.count == 1)

        // Stale: 31 min quiet, then the timer looks again.
        let other = makeModel(fake, clock)
        other.apply(event(.promptSubmitted, at: clock.now, prompt: "x"))
        await settle(other)
        let before = fake.calls.count
        clock.advance(31 * 60)
        other.summarizeNext()
        await settle(other)
        #expect(fake.calls.count == before)

        // Off: nothing, and turning off clears the lines.
        other.setEnabled(false)
        #expect(other.summaries.isEmpty)
        other.apply(event(.promptSubmitted, at: clock.now, prompt: "y"))
        other.summarizeNext()
        await settle(other)
        #expect(fake.calls.count == before)
    }

    @Test func waitsWhileHearthIsServing() async {
        let fake = FakeSummarizer(), clock = Clock()
        let model = makeModel(fake, clock)
        var serving = true
        model.isServing = { serving }
        model.apply(event(.promptSubmitted, at: clock.now, prompt: "Add a retry"))
        await settle(model)
        #expect(fake.calls.isEmpty)
        serving = false
        model.summarizeNext()
        await settle(model)
        #expect(fake.calls.count == 1)
    }

    @Test func permissionLineIsInstantEvenWhileBusy() async {
        let hanging = HangingSummarizer(), clock = Clock()
        let settings = AgentSettings(defaults: nil)
        settings.isEnabled = true
        let model = AgentsModel(settings: settings, summarizer: hanging, now: { clock.now })
        model.apply(event(.promptSubmitted, at: clock.now, prompt: "Push it"))   // the model call hangs
        #expect(model.summaryWork != nil)
        clock.advance(1)
        model.apply(event(.permissionRequested, at: clock.now, tool: "Bash", summary: "git push"))
        #expect(model.summaries[key] == "Wants to run git push")
        model.yieldToInference()
        await model.summaryWork?.value
        #expect(model.summaries[key] == "Wants to run git push")
    }

    @Test func stoppedTurnRepeatsTheLastWorkingLine() async {
        let fake = FakeSummarizer(), clock = Clock()
        let model = makeModel(fake, clock)
        model.apply(event(.promptSubmitted, at: clock.now, prompt: "Rename the module"))
        await settle(model)
        #expect(model.summaries[key] == "Running the uploader tests")
        clock.advance(1)
        model.apply(event(.interrupted, at: clock.now))
        await settle(model)
        #expect(model.summaries[key] == "Stopped: Running the uploader tests")
        #expect(fake.calls.count == 1)
    }

    @Test func stepsAsideForHearthsOwnRequests() async {
        let hanging = HangingSummarizer(), clock = Clock()
        let settings = AgentSettings(defaults: nil)
        settings.isEnabled = true
        let model = AgentsModel(settings: settings, summarizer: hanging, now: { clock.now })
        model.apply(event(.promptSubmitted, at: clock.now, prompt: "Add a retry"))
        #expect(model.summaryWork != nil)
        model.yieldToInference()
        await model.summaryWork?.value
        #expect(model.summaryWork == nil)
        #expect(model.summaries[key] == nil)            // no fallback written for a cancelled call
        // Still due: the next round starts it again.
        model.summarizeNext()
        #expect(model.summaryWork != nil)
        for _ in 0..<100 where hanging.calls < 2 { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(hanging.calls == 2)
        model.yieldToInference()
        await model.summaryWork?.value
    }

    @Test func fallsBackToTheLastTool() async {
        let fake = FakeSummarizer(), clock = Clock()
        fake.answer = nil
        let model = makeModel(fake, clock)
        model.apply(event(.promptSubmitted, at: clock.now, prompt: "Run the tests"))
        await settle(model)
        #expect(model.summaries[key] == nil)            // nothing to fall back to yet
        clock.advance(1)
        model.apply(event(.permissionRequested, at: clock.now, tool: "Bash", summary: "git log -1"))
        await settle(model)
        #expect(model.summaries[key] == "Wants to run git log")     // code, not the model
        #expect(fake.calls.count == 1)
        clock.advance(1)
        model.apply(event(.toolStarted, at: clock.now, tool: "Bash", summary: "git log -1"))
        model.apply(event(.turnEnded(backgroundTasks: []), at: clock.now))
        await settle(model)
        #expect(model.summaries[key] == "Running git log")
    }
}

struct AgentSummaryTextTests {
    @Test func tidiesTheModelsLine() {
        #expect(AgentSummaryLine.tidy("\"Running the uploader tests.\"\nMore text") == "Running the uploader tests")
        #expect(AgentSummaryLine.tidy("   ") == nil)
        #expect(AgentSummaryLine.tidy("waits for user") == "Waits for user")
        let long = AgentSummaryLine.tidy(String(repeating: "word ", count: 30))!
        #expect(long.count <= 70)
        #expect(long.hasSuffix("…"))
    }

    @Test func fallbackNamesTheLastTool() {
        func input(_ tools: [AgentSession.Tool]) -> AgentSummaryInput {
            AgentSummaryInput(agent: .claudeCode, project: "p", phase: .running, prompt: nil, tools: tools)
        }
        #expect(AgentSummaryLine.fallback(for: input([])) == nil)
        #expect(AgentSummaryLine.fallback(for: input([.init(name: "Bash", summary: "git log -1")])) == "Running git log")
        #expect(AgentSummaryLine.fallback(for: input([.init(name: "Read", summary: "Package.swift")])) == "Reading Package.swift")
        #expect(AgentSummaryLine.fallback(for: input([.init(name: "Edit", summary: nil)])) == "Editing (Edit)")
        #expect(AgentSummaryLine.fallback(for: input([.init(name: "mcp__db__query", summary: nil)])) == "Using mcp__db__query")
    }

    @Test func promptMarksAutomaticTurnsAndCutsPaths() {
        #expect(AgentSummaryInput.isAutomatic("<agent-message from=\"reviewer\">Verdict: OK</agent-message>"))
        #expect(AgentSummaryInput.isAutomatic("  <task-notification>\ndone"))
        #expect(!AgentSummaryInput.isAutomatic("Add a <Button> to the view"))
        #expect(!AgentSummaryInput.isAutomatic("Fix the login bug"))
        #expect(!AgentSummaryInput.isAutomatic("<div class=\"card\"> overflows on small screens, fix it"))

        let input = AgentSummaryInput(agent: .codex, project: "uploader", phase: .running,
                                      prompt: "<agent-message>Look at /Users/user/projects/uploader/Sources/Upload/Client.swift</agent-message>",
                                      promptIsAutomatic: true,
                                      tools: [.init(name: "Bash", summary: "cat ~/projects/uploader/README.md")])
        let text = input.promptText
        #expect(text.contains("automatic, from the agent itself, not from the user"))
        #expect(text.contains("Client.swift"))
        #expect(!text.contains("/Users/user"))
        #expect(text.contains("cat README.md"))
        #expect(text.count <= AgentSummaryInput.maxCharacters)
    }

    @Test func deterministicLines() {
        func line(_ phase: AgentPhase, pending: AgentSession.Tool? = nil, asking: String? = nil, stopped: Bool = false,
                  last: String? = nil, tools: [AgentSession.Tool] = []) -> String? {
            var input = AgentSummaryInput(agent: .claudeCode, project: "p", phase: phase, prompt: nil, tools: tools)
            input.pendingTool = pending
            input.askingSubagent = asking
            input.stoppedEarly = stopped
            return AgentSummaryLine.deterministic(for: input, lastWorkingLine: last)
        }
        #expect(line(.permission, pending: .init(name: "Bash", summary: "git push -u origin main")) == "Wants to run git push … main")
        #expect(line(.permission, pending: .init(name: "Edit", summary: "Package.swift")) == "Wants to edit Package.swift")
        #expect(line(.permission, pending: .init(name: "mcp__db__query", summary: nil)) == "Wants to use mcp__db__query")
        #expect(line(.permission, pending: .init(name: "Bash", summary: "API_TOKEN=abc ./deploy.sh")) == "Wants to run ./deploy.sh")
        #expect(line(.permission, asking: "reviewer") == "Reviewer wants permission")
        var described = AgentSummaryInput(agent: .claudeCode, project: "p", phase: .permission, prompt: nil)
        described.pendingTool = .init(name: "Bash", summary: "f=hearth-ui-test.txt; if [ -e $f ]; then rm $f; fi")
        described.pendingDescription = "Create hearth-ui-test.txt on the Desktop"
        #expect(AgentSummaryLine.deterministic(for: described, lastWorkingLine: nil) == "Wants to: Create hearth-ui-test.txt on the Desktop")
        described.pendingDescription = nil
        #expect(AgentSummaryLine.deterministic(for: described, lastWorkingLine: nil)
            == "Wants to run f=hearth-ui-test.txt; if [ -e $f ]; then rm $f; fi")     // not a plain command: as before
        #expect(AgentSummaryLine.shortCommand("cd Hearth && git push", tool: "Bash") == "git push")
        #expect(AgentSummaryLine.shortCommand("npm test 2>&1 | tail -20", tool: "Bash") == "npm test")
        #expect(AgentSummaryLine.shortCommand("git commit -m \"Fix bug\"", tool: "Bash") == "git commit")
        #expect(AgentSummaryLine.shortCommand("git -C repo status", tool: "Bash") == "git status")
        #expect(AgentSummaryLine.shortCommand("f=x; rm $f", tool: "Bash") == "f=x; rm $f")
        #expect(AgentSummaryLine.shortCommand("(cd x && make)", tool: "Bash") == "(cd x && make)")
        #expect(AgentSummaryLine.shortCommand("git push -u origin release/0.3", tool: "Bash") == "git push … release/0.3")
        #expect(AgentSummaryLine.shortCommand("rm -rf build", tool: "Bash") == "rm build")
        #expect(AgentSummaryLine.shortCommand("swift test", tool: "Bash") == "swift test")
        #expect(AgentSummaryLine.shortCommand("Package.swift", tool: "Edit") == "Package.swift")
        #expect(line(.permission) == "Wants permission")
        #expect(line(.waitingOn("reviewer")) == "Waiting for reviewer")
        #expect(line(.yourTurn, stopped: true, last: "Renaming the module") == "Stopped: Renaming the module")
        #expect(line(.yourTurn, stopped: true, tools: [.init(name: "Bash", summary: "grep -rl Old Sources")])
            == "Stopped: Running grep Old Sources")
        #expect(line(.yourTurn) == nil)          // the model writes these
        #expect(line(.running) == nil)
    }

    @Test func yourTurnStartIsChosenByCode() {
        func input(_ message: String?) -> AgentSummaryInput {
            AgentSummaryInput(agent: .claudeCode, project: "p", phase: .yourTurn, prompt: nil, lastMessage: message)
        }
        let asks = input("All 14 tests pass. Should I commit it?")
        #expect(asks.turnPrefix == "Asks whether")
        #expect(AgentSummaryLine.line(fromModel: "To commit the retry fix?", for: asks) == "Asks whether to commit the retry fix")
        #expect(AgentSummaryLine.line(fromModel: "Asks whether to commit", for: asks) == "Asks whether to commit")
        #expect(AgentSummaryLine.line(fromModel: "Should I commit the retry?", for: asks) == "Asks whether to commit the retry")
        let done = input("The dev server is running at localhost:5173.")
        #expect(done.turnPrefix == "Done:")
        #expect(AgentSummaryLine.line(fromModel: "dev server running on port 5173", for: done) == "Done: Dev server running on port 5173")
        #expect(AgentSummaryLine.line(fromModel: "Done: started the server", for: done) == "Done: started the server")
        // A question followed by options still asks; an open question gets "Asks"; a URL's "?" isn't a question.
        #expect(input("Which approach do you prefer?\n\n1. Keep the cache\n2. Drop it").turnPrefix == "Asks")
        #expect(input("Do you want the short version?\n- yes\n- no").turnPrefix == "Asks whether")
        #expect(input("Opened the PR: https://example.com/pull/12?w=1").turnPrefix == "Done:")
        #expect(AgentSummaryLine.line(fromModel: "Which approach to use", for: input("Which one?")) == "Asks which approach to use")
        var stopped = input("Should I go on?")
        stopped.stoppedEarly = true
        #expect(stopped.turnPrefix == nil)
        let working = AgentSummaryInput(agent: .claudeCode, project: "p", phase: .running, prompt: nil)
        #expect(AgentSummaryLine.line(fromModel: "Editing Backoff.swift.", for: working) == "Editing Backoff.swift")
        let searching = AgentSummaryInput(agent: .claudeCode, project: "p", phase: .running, prompt: nil,
                                          tools: [.init(name: "Grep", summary: "LegacyLogger")])
        #expect(AgentSummaryLine.line(fromModel: "Find every place we use the old logger", for: searching) == "Searching LegacyLogger")
        #expect(AgentSummaryLine.line(fromModel: "Running: swift test", for: searching) == "Running: swift test")
        let pattern = AgentSummaryInput(agent: .claudeCode, project: "p", phase: .running, prompt: nil,
                                        tools: [.init(name: "Grep", summary: "LegacyLogger\\.")])
        #expect(AgentSummaryLine.fallback(for: pattern) == "Searching LegacyLogger")
    }

    @Test func neverQuotesOrKeepsAnotherLanguage() {
        let turkish = AgentSummaryInput(agent: .claudeCode, project: "p", phase: .yourTurn, prompt: nil,
                                        lastMessage: "Reviewer düzeltmelerini işledim, 119b635 olarak push ettim.")
        #expect(AgentSummaryLine.line(fromModel: "Reviewer düzeltmelerini işledim, 119b635 olarak pu", for: turkish)
            == "Done: turn finished")
        #expect(AgentSummaryLine.line(fromModel: "Applied the reviewer fixes and pushed 119b635", for: turkish)
            == "Done: Applied the reviewer fixes and pushed 119b635")
        let english = AgentSummaryInput(agent: .claudeCode, project: "p", phase: .yourTurn, prompt: nil,
                                        lastMessage: "The retry is in place and all fourteen tests pass now. Should I commit it?")
        // English source: an echo is allowed (only non-English sources count as copies).
        #expect(AgentSummaryLine.line(fromModel: "the retry is in place and all fourteen tests pass", for: english)
            == "Asks whether the retry is in place and all fourteen tests pass")
        // An English message: repeating its feature name isn't a copy.
        let backoff = AgentSummaryInput(agent: .claudeCode, project: "p", phase: .yourTurn, prompt: nil,
                                        lastMessage: "Added a retry with exponential backoff to UploadClient.")
        #expect(AgentSummaryLine.line(fromModel: "Added retry with exponential backoff to UploadClient", for: backoff)
            == "Done: Added retry with exponential backoff to UploadClient")
        // Turkish without diacritics copied is still caught.
        let plain = AgentSummaryInput(agent: .claudeCode, project: "p", phase: .yourTurn, prompt: nil,
                                      lastMessage: "Düzeltmeleri bitirdim: 119b635 olarak push ettim ve 99 testin hepsi geçiyor.")
        #expect(AgentSummaryLine.line(fromModel: "119b635 olarak push ettim ve 99 testin", for: plain) == "Done: turn finished")
        #expect(AgentSummaryLine.line(fromModel: "119b635 olarak push ettim ve 99 testin", for: plain,
                                      lastWorkingLine: "Running git push") == "Running git push")
        let question = AgentSummaryInput(agent: .claudeCode, project: "p", phase: .yourTurn, prompt: nil,
                                         lastMessage: "Düzeltmeyi hazırladım. Commit'leyip push edeyim mi?")
        #expect(AgentSummaryLine.line(fromModel: "Commit'leyip push edeyim mi", for: question,
                                      lastWorkingLine: "Running git push") == "Asks you a question")
        // A non-ASCII file name from the tool hints is a name, not another language.
        let ceviri = AgentSummaryInput(agent: .claudeCode, project: "p", phase: .yourTurn, prompt: nil,
                                       tools: [.init(name: "Edit", summary: "Çeviri.swift")],
                                       lastMessage: "Fixed the plural rules.")
        #expect(AgentSummaryLine.line(fromModel: "Fixed the plural rules in Çeviri.swift", for: ceviri)
            == "Done: Fixed the plural rules in Çeviri.swift")
        #expect(AgentSummaryLine.isEnglishLooking("Editing Package.swift"))
        #expect(!AgentSummaryLine.isEnglishLooking("Düzeltmeleri işliyor"))
    }

    @Test func stopFailureAndInterruptMarkTheTurnStopped() {
        var store = AgentSessionStore()
        var stop = AgentEvent(agent: .claudeCode, sessionID: "s", kind: .turnEnded(backgroundTasks: []), time: .now)
        store.apply(AgentEvent(agent: .claudeCode, sessionID: "s", kind: .promptSubmitted, time: .now))
        stop.failed = true
        store.apply(stop)
        #expect(store.sessions.values.first?.stoppedEarly == true)
        store.apply(AgentEvent(agent: .claudeCode, sessionID: "s", kind: .promptSubmitted, time: .now))
        #expect(store.sessions.values.first?.stoppedEarly == false)
        #expect(AgentEventDecoder.decode(Data(#"{"session_id":"s","hook_event_name":"StopFailure"}"#.utf8),
                                         agent: .claudeCode, receivedAt: .now)?.failed == true)
    }

    @Test func masksObviousSecrets() {
        let clean = { AgentSummaryInput.clean($0, limit: 200) }
        #expect(clean("API_TOKEN=sk-test-4f9a2b ./scripts/deploy.sh staging") == "API_TOKEN=… ./scripts/deploy.sh staging"
            || clean("API_TOKEN=sk-test-4f9a2b ./scripts/deploy.sh staging") == "API_TOKEN=… deploy.sh staging")
        #expect(clean("curl -H 'Authorization: Bearer abc.def' https://example.com") == "curl -H 'Authorization: Bearer …' https://example.com")
        #expect(clean("tool login --token xyz123 --verbose") == "tool login --token … --verbose")
        #expect(!clean("git clone https://me:hunter2@example.com/repo.git").contains("hunter2"))
        #expect(AgentSummaryInput.maskSecrets("https://me:hunter2@example.com") == "https://me:…@example.com")
        #expect(clean("DB_PASSWORD='p a s s' ./migrate") == "DB_PASSWORD=… ./migrate")
        // Left alone: no secret shape.
        #expect(clean("CONFIGURATION=Release xcodebuild") == "CONFIGURATION=Release xcodebuild")
        #expect(clean("swift test --filter TokenTests") == "swift test --filter TokenTests")
        #expect(clean("git log --author=alice --since=1.week") == "git log --author=alice --since=1.week")
        #expect(clean("sort --key=2 data.txt") == "sort --key=2 data.txt")
        #expect(AgentSummaryInput.maskSecrets(#"curl "https://x.test/api?api_key=abc&page=2""#) == #"curl "https://x.test/api?api_key=…&page=2""#)
        // Known limits: a bare token argument isn't recognized.
        #expect(clean("./deploy.sh sk-abc123").contains("sk-abc123"))
        // The fallback line uses the same cleaning.
        let input = AgentSummaryInput(agent: .claudeCode, project: "p", phase: .running, prompt: nil,
                                      tools: [.init(name: "Bash", summary: "API_TOKEN=sk-test-4f9a2b deploy.sh staging")])
        #expect(AgentSummaryLine.fallback(for: input) == "Running deploy.sh staging")
    }

    @Test func promptIsCutToThreeThousandCharacters() {
        let input = AgentSummaryInput(agent: .claudeCode, project: "p", phase: .running,
                                      prompt: String(repeating: "a ", count: 5_000),
                                      tools: Array(repeating: .init(name: "Bash", summary: String(repeating: "b", count: 500)), count: 5),
                                      lastMessage: String(repeating: "c ", count: 5_000))
        #expect(input.promptText.count <= 3_000)
    }
}
