import Foundation
import Observation

/// The agent sessions the UI shows. Events arrive from the endpoint; a timer drops sessions that are gone.
@MainActor
@Observable
final class AgentsModel {
    private(set) var store = AgentSessionStore()
    let settings: AgentSettings
    @ObservationIgnored private var sweeper: Task<Void, Never>?

    init(settings: AgentSettings = AgentSettings()) {
        self.settings = settings
    }

    /// For the HTTP server: hands events to the main actor without waiting.
    nonisolated var endpoint: AgentEndpoint {
        AgentEndpoint(settings: settings) { [weak self] event in
            Task { @MainActor in self?.apply(event) }
        }
    }

    func apply(_ event: AgentEvent) {
        guard settings.isEnabled else { return }
        store.apply(event)
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
}
