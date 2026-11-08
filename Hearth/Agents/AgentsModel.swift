import Foundation
import Observation

/// The agent sessions the UI shows. Events arrive from the endpoint; a timer drops sessions that are gone.
/// Also connects and disconnects the agents' hooks, only when the user asks.
@MainActor
@Observable
final class AgentsModel {
    private(set) var store = AgentSessionStore()
    /// Events accepted since launch; a debug count until the Agents section exists.
    private(set) var eventCount = 0
    /// Hook state per agent, refreshed when the panel opens and after Connect / Disconnect.
    private(set) var hookStatus: [AgentKind: AgentInstaller.Status] = [:]
    /// The one-line summary per session (Apple Intelligence, or the last tool as a fallback).
    private(set) var summaries: [AgentSession.Key: String] = [:]
    let settings: AgentSettings
    @ObservationIgnored private var sweeper: Task<Void, Never>?
    @ObservationIgnored private let home: URL
    @ObservationIgnored private let summarizer: any AgentSummarizer
    @ObservationIgnored private let now: @MainActor () -> Date
    /// True while Hearth serves an inference request: summaries wait, they never slow Hearth's own work.
    @ObservationIgnored var isServing: @MainActor () -> Bool = { false }
    @ObservationIgnored private var summarized: [AgentSession.Key: (phase: AgentPhase, at: Date)] = [:]
    /// The latest line written while each session was working, for "Stopped: …".
    @ObservationIgnored private var workingLines: [AgentSession.Key: String] = [:]
    /// The summary being written, if any; one at a time.
    @ObservationIgnored private(set) var summaryWork: Task<Void, Never>?

    static let summaryInterval: TimeInterval = 20

    /// Mirrors the stored switch so SwiftUI sees changes (AgentSettings isn't observable).
    private(set) var isEnabled: Bool

    init(settings: AgentSettings = AgentSettings(), home: URL = FileManager.default.homeDirectoryForCurrentUser,
         summarizer: any AgentSummarizer = AppleAgentSummarizer(), now: @escaping @MainActor () -> Date = { .now }) {
        self.settings = settings
        self.home = home
        self.summarizer = summarizer
        self.now = now
        isEnabled = settings.isEnabled
    }

    /// For the HTTP server: hands events to the main actor without waiting.
    nonisolated var endpoint: AgentEndpoint {
        AgentEndpoint(settings: settings) { [weak self] event in
            Task { @MainActor in self?.apply(event) }
        }
    }

    /// Turning Agents off also forgets every session (prompts included).
    func setEnabled(_ enabled: Bool) {
        settings.isEnabled = enabled
        isEnabled = enabled
        if !enabled {
            store = AgentSessionStore()
            eventCount = 0
            summaries = [:]
            summarized = [:]
            workingLines = [:]
        }
    }

    func apply(_ event: AgentEvent) {
        guard settings.isEnabled else { return }
        store.apply(event)
        eventCount += 1
        if event.kind == .promptSubmitted, event.subagentID == nil {
            workingLines[AgentSession.Key(agent: event.agent, sessionID: event.sessionID)] = nil
        }
        summarizeNext()
    }

    func startSweeping() {
        guard sweeper == nil else { return }
        sweeper = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self else { return }
                self.store.sweep(at: self.now())
                let keys = Set(self.store.sessions.keys)
                self.summaries = self.summaries.filter { keys.contains($0.key) }
                self.summarized = self.summarized.filter { keys.contains($0.key) }
                self.workingLines = self.workingLines.filter { keys.contains($0.key) }
            }
        }
        // Retries summaries skipped or cancelled while Hearth was serving a request.
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self else { return }
                self.summarizeNext()
            }
        }
    }

    // MARK: - Summaries

    /// Starts the next due summary, if nothing else is being written and Hearth isn't serving a request.
    func summarizeNext() {
        guard isEnabled else { return }
        let time = now()
        // Lines code knows exactly come first and at once, even while the model or Hearth is busy.
        for session in store.visibleSessions(at: time) where isDue(session, at: time) {
            let input = AgentSummaryInput(session: session)
            guard let line = AgentSummaryLine.deterministic(for: input, lastWorkingLine: workingLines[session.id])
            else { continue }
            summarized[session.id] = (session.effectivePhase, time)
            summaries[session.id] = line
        }
        guard summaryWork == nil, !isServing() else { return }
        let due = store.visibleSessions(at: time).first { isDue($0, at: time) }
        guard let session = due else { return }
        let key = session.id, phase = session.effectivePhase
        let input = AgentSummaryInput(session: session)
        let previous = summarized[key]
        summarized[key] = (phase, time)
        let summarizer = self.summarizer
        summaryWork = Task(priority: .background) { [weak self] in
            let raw = try? await summarizer.summarize(input)
            await MainActor.run {
                guard let self else { return }
                self.summaryWork = nil
                // Stepped aside for one of Hearth's own requests: due again, the ticker retries later.
                if Task.isCancelled {
                    // Only undo our own mark; a newer one (e.g. a permission line) stays.
                    if self.summarized[key]?.phase == phase, self.summarized[key]?.at == time { self.summarized[key] = previous }
                    return
                }
                // Dropped meanwhile (Agents turned off, session swept): don't bring it back.
                if self.isEnabled, self.store.sessions[key] != nil, self.summarized[key]?.phase == phase {
                    self.summaries[key] = raw.flatMap { AgentSummaryLine.line(fromModel: $0, for: input) }
                        ?? AgentSummaryLine.fallback(for: input)
                        ?? self.summaries[key]
                    if phase == .running, let line = self.summaries[key] { self.workingLines[key] = line }
                }
                self.summarizeNext()
            }
        }
    }

    /// Hearth is about to serve a request: stop the summary in flight (the model frees at once on cancel).
    func yieldToInference() {
        summaryWork?.cancel()
    }

    /// On every change of state, and at most every 20 s while running with new activity. Never for ended or
    /// stale sessions.
    private func isDue(_ session: AgentSession, at time: Date) -> Bool {
        guard session.phase != .ended, store.displayState(of: session, at: time) != .stale else { return false }
        guard let last = summarized[session.id] else { return session.phase != .idle || session.lastPrompt != nil }
        if last.phase != session.effectivePhase { return true }
        return session.phase == .running && time.timeIntervalSince(last.at) >= Self.summaryInterval
            && session.lastEventAt > last.at
    }

    // MARK: - Hooks

    func refreshHookStatus(port: Int?) {
        guard let port else { return }
        for agent in AgentKind.allCases {
            let data = try? Data(contentsOf: AgentInstaller.settingsURL(for: agent, home: home))
            hookStatus[agent] = AgentInstaller.status(data, agent: agent, port: port, token: settings.token)
        }
    }

    /// Adds (or rewrites) Hearth's hooks for `agent` and turns Agents on.
    func connect(_ agent: AgentKind, port: Int) throws {
        let url = AgentInstaller.settingsURL(for: agent, home: home)
        let original = try? Data(contentsOf: url)
        let updated = try AgentInstaller.connect(original, agent: agent, port: port, token: settings.token,
                                                 path: Self.displayPath(url))
        try AgentInstaller.write(updated, to: url)
        setEnabled(true)
        refreshHookStatus(port: port)
    }

    /// Removes exactly Hearth's hooks for `agent`.
    func disconnect(_ agent: AgentKind, port: Int?) throws {
        let url = AgentInstaller.settingsURL(for: agent, home: home)
        guard let original = try? Data(contentsOf: url) else { return }
        let updated = try AgentInstaller.disconnect(original, agent: agent, path: Self.displayPath(url))
        try AgentInstaller.write(updated, to: url)
        refreshHookStatus(port: port)
    }

    static func codexConfigHasHooks(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let url = home.appendingPathComponent(".codex/config.toml")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return AgentInstaller.codexConfigHasHooks(text)
    }

    static func displayPath(_ url: URL) -> String {
        url.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }
}
