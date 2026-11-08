import SwiftUI
import AppKit

/// Agents items in the gear menu: the switch, and Connect / Disconnect / Fix per agent.
/// Minimal on purpose; the Agents section in the panel comes later.
struct AgentsMenuItems: View {
    let agents: AgentsModel
    let port: Int?

    var body: some View {
        Section(agents.isEnabled ? "Agents: on · \(agents.eventCount) events" : "Agents: off") {
            Button(agents.isEnabled ? "Turn Agents Off" : "Turn Agents On") { agents.setEnabled(!agents.isEnabled) }
            ForEach(AgentKind.allCases, id: \.self) { agent in
                item(for: agent)
            }
        }
    }

    @ViewBuilder
    private func item(for agent: AgentKind) -> some View {
        switch agents.hookStatus[agent] ?? .notConnected {
        case .notConnected:
            Button("Connect \(agent.displayName)…") { connect(agent) }
                .disabled(port == nil)
        case .connected:
            Button("Disconnect \(agent.displayName)") { disconnect(agent) }
        case .needsFix(let other):
            Button("Fix \(agent.displayName) Hooks" + (other.flatMap { $0 == port ? nil : " (port \($0))" } ?? "")) {
                connect(agent)
            }
                .disabled(port == nil)
            Button("Disconnect \(agent.displayName)") { disconnect(agent) }
        }
    }

    private func connect(_ agent: AgentKind) {
        guard let port else { return }
        let path = AgentsModel.displayPath(AgentInstaller.settingsURL(for: agent))
        var text = "Hearth adds hooks to \(path) so it can show what \(agent.displayName) is doing. "
            + "A backup of the file is saved next to it first. Disconnect removes exactly these hooks."
        if agent == .codex, AgentsModel.codexConfigHasHooks() {
            text += "\n\nYour ~/.codex/config.toml has hooks of its own. Codex runs both and shows a warning at startup."
        }
        guard confirm("Connect \(agent.displayName)?", text) else { return }
        do {
            try agents.connect(agent, port: port)
            if agent == .codex {
                inform("Trust the hooks in Codex",
                       "Open Codex, run /hooks once and trust Hearth's hooks. Codex skips new hooks until you do.")
            }
        } catch {
            inform("Couldn't connect \(agent.displayName)", error.localizedDescription)
        }
    }

    private func disconnect(_ agent: AgentKind) {
        do { try agents.disconnect(agent, port: port) } catch {
            inform("Couldn't disconnect \(agent.displayName)", error.localizedDescription)
        }
    }

    private func confirm(_ title: String, _ text: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func inform(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        NSApp.activate()
        alert.runModal()
    }
}
