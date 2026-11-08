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
        #expect(model.summaries[key] == nil)            // a permission request isn't a tool call
        clock.advance(1)
        model.apply(event(.toolStarted, at: clock.now, tool: "Bash", summary: "git log -1"))
        model.apply(event(.turnEnded(backgroundTasks: []), at: clock.now))
        await settle(model)
        #expect(model.summaries[key] == "Running git log -1")
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
        #expect(AgentSummaryLine.fallback(for: input([.init(name: "Bash", summary: "git log -1")])) == "Running git log -1")
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
        #expect(AgentSummaryLine.fallback(for: input) == "Running API_TOKEN=… deploy.sh staging")
    }

    @Test func promptIsCutToThreeThousandCharacters() {
        let input = AgentSummaryInput(agent: .claudeCode, project: "p", phase: .running,
                                      prompt: String(repeating: "a ", count: 5_000),
                                      tools: Array(repeating: .init(name: "Bash", summary: String(repeating: "b", count: 500)), count: 5),
                                      lastMessage: String(repeating: "c ", count: 5_000))
        #expect(input.promptText.count <= 3_000)
    }
}
