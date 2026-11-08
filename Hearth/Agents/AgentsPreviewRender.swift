#if DEBUG
import SwiftUI
import AppKit

/// Debug builds only: `Hearth --agents-render <folder>` writes PNGs of the Agents section with made-up
/// sessions, light and dark, for the report. Never part of a release build.
enum AgentsPreviewRender {
    static let flag = "--agents-render"

    @MainActor
    static func run(to folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let now = Date()
        func row(_ name: String, _ agent: AgentKind, _ state: AgentDisplayState, ago: TimeInterval, _ line: String?,
                 note: String? = nil, children: [AgentSubagent] = []) -> AgentRow {
            AgentRow(id: .init(agent: agent, sessionID: name), agent: agent, name: name, state: state,
                     since: now.addingTimeInterval(-ago), line: line, note: note, children: children)
        }
        let reviewer = AgentSubagent(id: "a1", type: "reviewer", phase: .running, phaseSince: now.addingTimeInterval(-70),
                                     startedAt: now.addingTimeInterval(-70))
        let askingReviewer = AgentSubagent(id: "a2", type: "reviewer", phase: .permission, phaseSince: now.addingTimeInterval(-6),
                                           startedAt: now.addingTimeInterval(-40))
        let rows = [
            row("uploader", .claudeCode, .phase(.permission), ago: 4, "Wants to: Push the release branch to origin"),
            row("coding → Hearth", .claudeCode, .phase(.running), ago: 40, "Reviewer wants permission",
                children: [askingReviewer]),
            row("uploader #2", .claudeCode, .phase(.waitingOn("reviewer")), ago: 72, "Waiting for reviewer",
                children: [reviewer]),
            row("billing", .codex, .phase(.running), ago: 134, "Running test command to diagnose CI build failure"),
            row("website", .claudeCode, .phase(.yourTurn), ago: 185, "Asks whether to commit the retry with exponential backoff"),
            row("docs", .claudeCode, .phase(.yourTurn), ago: 610, "Done: Dev server running at localhost:5173",
                note: "npm run dev"),
            row("notes", .codex, .stale, ago: 2_520, "Editing README.md to update the install section"),
            row("scripts", .claudeCode, .phase(.ended), ago: 300, "Session ended"),
        ]
        let cases: [(String, AnyView)] = [
            ("sessions", AnyView(AgentsSection(rows: Array(rows.prefix(6)), now: now, nothingConnected: false))),
            ("one-connected", AnyView(AgentsSection(rows: Array(rows.suffix(2)), now: now, nothingConnected: false,
                                                     unconnected: [.codex]))),
            ("empty", AnyView(AgentsSection(rows: [], now: now, nothingConnected: false))),
            ("connect", AnyView(AgentsSection(rows: [], now: now, nothingConnected: true))),
        ]
        for (name, view) in cases {
            for scheme in [ColorScheme.light, .dark] {
                let content = view
                    .padding(14)
                    .frame(width: 340, alignment: .leading)
                    .background(scheme == .dark ? Color(white: 0.17) : Color(white: 0.97))
                    .environment(\.colorScheme, scheme)
                let renderer = ImageRenderer(content: content)
                renderer.scale = 2
                guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                      let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { continue }
                let url = folder.appendingPathComponent("agents-\(name)-\(scheme == .dark ? "dark" : "light").png")
                try? png.write(to: url)
                print(url.path)
            }
        }
    }
}
#endif
