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
    let settings: AgentSettings
    @ObservationIgnored private var sweeper: Task<Void, Never>?
    @ObservationIgnored private let home: URL

    /// Mirrors the stored switch so SwiftUI sees changes (AgentSettings isn't observable).
    private(set) var isEnabled: Bool

    init(settings: AgentSettings = AgentSettings(), home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.settings = settings
        self.home = home
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
        }
    }

    func apply(_ event: AgentEvent) {
        guard settings.isEnabled else { return }
        store.apply(event)
        eventCount += 1
    }

    func startSweeping() {
        guard sweeper == nil else { return }
        sweeper = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self else { return }
                self.store.sweep(at: .now)
            }
        }
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
