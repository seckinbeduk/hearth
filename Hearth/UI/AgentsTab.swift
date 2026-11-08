import SwiftUI

/// The Details window's Agents tab: the live sessions as a grid of cards; a card opens its recent activity.
/// Same data as the panel (memory only); nothing here is stored.
struct AgentsTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            AgentsGrid(rows: model.agents.isEnabled ? model.agents.rows(at: context.date) : [],
                       now: context.date, isEnabled: model.agents.isEnabled,
                       nothingConnected: model.agents.nothingConnected,
                       unconnected: model.agents.unconnected, canConnect: model.server.port != nil,
                       connect: { AgentConnector(agents: model.agents, port: model.server.port).connect($0) },
                       turnOn: { model.agents.setEnabled(true) })
        }
        .onAppear { model.agents.refreshHookStatus(port: model.server.port) }
    }
}

/// The grid itself, from plain data (previewable).
struct AgentsGrid: View {
    let rows: [AgentRow]
    let now: Date
    var isEnabled = true
    var nothingConnected = false
    var unconnected: [AgentKind] = []
    var canConnect = true
    var connect: (AgentKind) -> Void = { _ in }
    var turnOn: () -> Void = {}
    @State private var opened: AgentSession.Key?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !isEnabled {
                ContentUnavailableView {
                    Label("Agents is off", systemImage: "terminal")
                } description: {
                    Text("Turn it on to see your coding agents here.")
                } actions: {
                    Button("Turn Agents On", action: turnOn)
                }
            } else if nothingConnected {
                ContentUnavailableView {
                    Label("No agents connected", systemImage: "terminal")
                } description: {
                    Text("See what Claude Code and Codex are doing, and when it's your turn.")
                } actions: {
                    connectButtons(AgentKind.allCases)
                }
            } else if rows.isEmpty {
                ContentUnavailableView("No agent sessions right now", systemImage: "terminal",
                                       description: Text("Sessions show up with their next event."))
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250, maximum: 420), spacing: 12, alignment: .top)], spacing: 12) {
                    ForEach(rows) { row in
                        Button { opened = row.id } label: { AgentCard(row: row, now: now) }
                            .buttonStyle(.plain)
                    }
                }
            }
            if isEnabled, !nothingConnected, !unconnected.isEmpty {
                connectButtons(unconnected)
            }
        }
        .sheet(item: Binding(get: { opened.map(OpenedKey.init) }, set: { opened = $0?.key })) { item in
            if let row = rows.first(where: { $0.id == item.key }) {
                AgentDetailView(row: row, now: now) { opened = nil }
            } else {
                GoneSessionView { opened = nil }
            }
        }
    }

    private func connectButtons(_ agents: [AgentKind]) -> some View {
        HStack {
            ForEach(agents, id: \.self) { agent in
                Button("Connect \(agent.displayName)…") { connect(agent) }
                    .disabled(!canConnect)
                    .fixedSize()
            }
        }
    }

    private struct OpenedKey: Identifiable {
        let key: AgentSession.Key
        var id: String { key.agent.rawValue + key.sessionID }
    }
}

/// One session as a card: agent, project, state and time, two lines of summary, subagent chips.
/// The border follows the state; permission and "your turn" stand out most.
struct AgentCard: View {
    let row: AgentRow
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: AgentRowView.symbol(for: row.agent))
                    .foregroundStyle(AgentRowView.tint(for: row.agent))
                    .accessibilityLabel(row.agent.displayName)
                Text(row.name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 4)
                AgentStateLabel(state: row.state)
                Text(AgentRowView.elapsed(since: row.since, now: now))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Text(row.line ?? "—")
                .font(.callout)
                .foregroundStyle(row.state == .stale ? .secondary : .primary)
                .lineLimit(2, reservesSpace: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let note = row.note {
                Label("running: \(note)", systemImage: "gearshape.2")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if !row.children.isEmpty {
                HStack(spacing: 6) {
                    ForEach(row.children) { child in
                        let (state, _, _) = AgentStateLabel.style(for: .phase(child.phase))
                        Text("\(child.type) · \(state.lowercased())")
                            .font(.caption)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15), in: .capsule)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Theme.card, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Self.border(for: row.state), lineWidth: Self.borderWidth(for: row.state)))
        .contentShape(.rect)
    }

    static func border(for state: AgentDisplayState) -> Color {
        switch state {
        case .phase(.permission): Theme.flame
        case .phase(.yourTurn): Theme.ready
        case .phase(.running), .phase(.waitingOn): Theme.apple.opacity(0.45)
        default: Color.primary.opacity(0.1)
        }
    }

    static func borderWidth(for state: AgentDisplayState) -> CGFloat {
        switch state {
        case .phase(.permission), .phase(.yourTurn): 2
        default: 1
        }
    }
}

/// An opened card: full summary, folder, subagents and the last ~20 events (masked; no prompts or messages).
struct AgentDetailView: View {
    let row: AgentRow
    let now: Date
    var close: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: AgentRowView.symbol(for: row.agent))
                    .foregroundStyle(AgentRowView.tint(for: row.agent))
                Text(row.name).font(.title2.weight(.semibold))
                AgentStateLabel(state: row.state)
                Text(AgentRowView.elapsed(since: row.since, now: now))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            }
            if let line = row.line {
                Text(line).font(.body).textSelection(.enabled)
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow {
                    Text("Agent").foregroundStyle(.secondary)
                    Text(row.agent.displayName)
                }
                if let cwd = row.cwd {
                    GridRow {
                        Text("Folder").foregroundStyle(.secondary)
                        Text((cwd as NSString).abbreviatingWithTildeInPath).textSelection(.enabled)
                    }
                }
                if let prompt = row.latestPrompt {
                    GridRow {
                        Text("Last prompt").foregroundStyle(.secondary)
                        Text(prompt).lineLimit(1)
                    }
                }
                if !row.children.isEmpty {
                    GridRow {
                        Text("Subagents").foregroundStyle(.secondary)
                        Text(row.children.map { "\($0.type) (\(AgentStateLabel.style(for: .phase($0.phase)).0.lowercased()))" }
                            .joined(separator: ", "))
                    }
                }
                if let note = row.note {
                    GridRow {
                        Text("Running").foregroundStyle(.secondary)
                        Text(note)
                    }
                }
            }
            .font(.callout)

            Text("Recent activity").font(.headline)
            if row.activity.isEmpty {
                Text("Nothing yet.").foregroundStyle(.secondary)
            } else {
                List(row.activity.reversed()) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(item.time, format: .dateTime.hour().minute().second())
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text(item.title)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        if let phase = item.newPhase {
                            AgentStateLabel(state: .phase(phase), compact: true)
                        }
                    }
                    .font(.callout)
                }
                .listStyle(.inset)
                .frame(minHeight: 260)
            }
            Text("Kept in memory only and cleared when Agents is turned off. Only the first line of the latest "
                 + "prompt is shown, with secrets masked; the agents' messages aren't shown.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(20)
        .frame(width: 560)
    }
}

/// The opened session went away (ended and hidden, or Agents was turned off).
struct GoneSessionView: View {
    var close: () -> Void = {}

    var body: some View {
        VStack(spacing: 12) {
            ContentUnavailableView("This session is no longer shown", systemImage: "terminal",
                                   description: Text("It ended a while ago, or Agents was turned off."))
            Button("Done", action: close).keyboardShortcut(.defaultAction)
        }
        .padding(20)
        .frame(width: 420)
    }
}

#if DEBUG
enum AgentsPreviewData {
    static let now = Date()
    static func row(_ name: String, _ agent: AgentKind, _ state: AgentDisplayState, ago: TimeInterval, _ line: String?,
                    note: String? = nil, children: [AgentSubagent] = [], activity: [AgentActivity] = []) -> AgentRow {
        AgentRow(id: .init(agent: agent, sessionID: name), agent: agent, name: name, state: state,
                 since: now.addingTimeInterval(-ago), line: line, note: note, children: children,
                 cwd: "/Users/user/projects/\(name.split(separator: " ").first ?? "")", activity: activity,
                 latestPrompt: "Add a retry with exponential backoff to the upload client")
    }
    static let reviewer = AgentSubagent(id: "a1", type: "reviewer", phase: .running,
                                        phaseSince: now.addingTimeInterval(-70), startedAt: now.addingTimeInterval(-70))
    static let activity: [AgentActivity] = {
        let steps: [(String, String?, String?, String?, AgentPhase?)] = [
            ("promptSubmitted", nil, nil, nil, .running),
            ("toolStarted", nil, "Read", "UploadClient.swift", nil),
            ("toolFinished", nil, "Read", "UploadClient.swift", nil),
            ("toolStarted", nil, "Edit", "UploadClient.swift", nil),
            ("toolFinished", nil, "Edit", "UploadClient.swift", nil),
            ("toolStarted", nil, "Agent", "reviewer", nil),
            ("subagentStarted", "reviewer", nil, nil, nil),
            ("toolStarted", "reviewer", "Bash", "git diff", nil),
            ("toolFinished", "reviewer", "Bash", "git diff", nil),
            ("turnEnded(1)", nil, nil, nil, .waitingOn("reviewer")),
        ]
        return steps.enumerated().map { index, step in
            AgentActivity(time: now.addingTimeInterval(Double(index - steps.count) * 7), kind: step.0, subagent: step.1,
                          tool: step.2, hint: step.3, newPhase: step.4)
        }
    }()
    static let rows: [AgentRow] = [
        row("uploader", .claudeCode, .phase(.permission), ago: 4, "Wants to: Push the release branch to origin"),
        row("uploader #2", .claudeCode, .phase(.waitingOn("reviewer")), ago: 72, "Waiting for reviewer",
            children: [reviewer], activity: activity),
        row("billing", .codex, .phase(.running), ago: 134, "Running test command to diagnose CI build failure"),
        row("website", .claudeCode, .phase(.yourTurn), ago: 185, "Asks whether to commit the retry with exponential backoff"),
        row("docs", .claudeCode, .phase(.yourTurn), ago: 610, "Done: Dev server running at localhost:5173", note: "npm run dev"),
        row("notes", .codex, .stale, ago: 2_520, "Editing README.md to update the install section"),
    ]
}

#Preview("Agents grid") {
    AgentsGrid(rows: AgentsPreviewData.rows, now: AgentsPreviewData.now)
        .padding(24)
        .frame(width: 820, height: 560, alignment: .top)
}

#Preview("Opened card") {
    AgentDetailView(row: AgentsPreviewData.rows[1], now: AgentsPreviewData.now)
}

#Preview("Session gone") {
    GoneSessionView()
}

#Preview("No agents connected") {
    AgentsGrid(rows: [], now: .now, nothingConnected: true)
        .padding(24)
        .frame(width: 820, height: 320, alignment: .top)
}
#endif
