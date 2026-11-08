import SwiftUI
import AppKit

/// The Agents section in the panel: one row per coding-agent session, subagents under their parent.
struct AgentsSection: View {
    let rows: [AgentRow]
    let now: Date
    /// No agent is connected yet: offer to connect instead of an empty list.
    let nothingConnected: Bool
    /// Agents not connected yet, offered below the rows (one agent connected doesn't hide the other).
    var unconnected: [AgentKind] = []
    /// Connecting needs Hearth's port, so the server must be up.
    var canConnect = true
    var connect: (AgentKind) -> Void = { _ in }

    static let maxRows = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Agents")
                .font(.caption)
                .foregroundStyle(.secondary)
            if nothingConnected {
                VStack(alignment: .leading, spacing: 6) {
                    Text("See what Claude Code and Codex are doing, and when it's your turn.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        ForEach(AgentKind.allCases, id: \.self) { agent in
                            Button("Connect \(agent.displayName)…") { connect(agent) }
                                .disabled(!canConnect)
                        }
                    }
                    .controlSize(.small)
                }
            } else if rows.isEmpty {
                Text("No agent sessions right now.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(rows.prefix(Self.maxRows)) { row in
                        AgentRowView(row: row, now: now)
                        if row.id != rows.prefix(Self.maxRows).last?.id { Divider() }
                    }
                }
                if rows.count > Self.maxRows {
                    Text("\(rows.count - Self.maxRows) more")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            if !nothingConnected, !unconnected.isEmpty {
                // Bordered buttons: ImageRenderer draws link-style buttons as a placeholder.
                HStack(spacing: 8) {
                    ForEach(unconnected, id: \.self) { agent in
                        Button("Connect \(agent.displayName)…") { connect(agent) }
                            .disabled(!canConnect)
                    }
                }
                .controlSize(.small)
                .padding(.top, 2)
            }
        }
    }
}

struct AgentRowView: View {
    let row: AgentRow
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: Self.symbol(for: row.agent))
                    .foregroundStyle(Self.tint(for: row.agent))
                    .frame(width: 16)
                    .help(row.agent.displayName)
                    .accessibilityLabel(row.agent.displayName)
                Text(row.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                AgentStateLabel(state: row.state)
                Text(Self.elapsed(since: row.since, now: now))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(minWidth: 30, alignment: .trailing)
            }
            if let line = row.line {
                Text(line)
                    .font(.caption)
                    .foregroundStyle(row.state == .stale ? .tertiary : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, 22)
            }
            if let note = row.note {
                Label("running: \(note)", systemImage: "gearshape.2")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.leading, 22)
            }
            ForEach(row.children) { child in
                HStack(spacing: 6) {
                    Image(systemName: "arrow.turn.down.right")
                        .foregroundStyle(.tertiary)
                    Text(child.type)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    AgentStateLabel(state: .phase(child.phase), compact: true)
                    Text(Self.elapsed(since: child.startedAt, now: now))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(minWidth: 30, alignment: .trailing)
                }
                .font(.caption)
                .padding(.leading, 22)
            }
        }
        .padding(.vertical, 6)
    }

    /// Different shape and colour per agent, so the two never look alike at a glance.
    static func symbol(for agent: AgentKind) -> String {
        switch agent {
        case .claudeCode: "terminal.fill"
        case .codex: "curlybraces.square.fill"
        }
    }

    static func tint(for agent: AgentKind) -> Color {
        switch agent {
        case .claudeCode: Color(red: 0.80, green: 0.47, blue: 0.33)
        case .codex: Color(red: 0.20, green: 0.60, blue: 0.62)
        }
    }

    /// "8s", "4m", "1h 5m".
    static func elapsed(since start: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3_600 { return "\(seconds / 60)m" }
        let minutes = (seconds % 3_600) / 60
        return minutes == 0 ? "\(seconds / 3_600)h" : "\(seconds / 3_600)h \(minutes)m"
    }
}

/// The state as a small capsule. Permission is the strongest (filled), "your turn" next.
struct AgentStateLabel: View {
    let state: AgentDisplayState
    var compact = false

    var body: some View {
        let (text, color, filled) = Self.style(for: state)
        Text(text)
            .font((compact ? Font.caption2 : .caption).weight(filled ? .semibold : .medium))
            .padding(.horizontal, compact ? 5 : 7)
            .padding(.vertical, 2)
            .foregroundStyle(filled ? Color.white : color)
            .background(filled ? color : color.opacity(0.2), in: .capsule)
            .lineLimit(1)
            .fixedSize()
    }

    /// Text colours that keep their contrast on the tinted capsule in both themes.
    static let workingText = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.66, green: 0.71, blue: 1.0, alpha: 1) : NSColor(red: 0.16, green: 0.22, blue: 0.68, alpha: 1)
    })
    static let yourTurnText = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.45, green: 0.86, blue: 0.60, alpha: 1) : NSColor(red: 0.03, green: 0.35, blue: 0.18, alpha: 1)
    })

    static func style(for state: AgentDisplayState) -> (String, Color, Bool) {
        switch state {
        case .stale: ("Quiet", .secondary, false)
        case .phase(let phase):
            switch phase {
            case .idle: ("Started", .secondary, false)
            case .running: ("Working", Self.workingText, false)
            case .permission: ("Permission", Theme.flame, true)
            case .yourTurn: ("Your turn", Self.yourTurnText, false)
            case .waitingOn: ("Waiting", .secondary, false)
            case .ended: ("Ended", .secondary, false)
            }
        }
    }
}

#if DEBUG
#Preview("Panel: Agents section") {
    AgentsSection(rows: AgentsPreviewData.rows, now: AgentsPreviewData.now, nothingConnected: false)
        .padding(14)
        .frame(width: 340, alignment: .leading)
}
#endif
