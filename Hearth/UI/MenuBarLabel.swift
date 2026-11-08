import AppKit
import SwiftUI
import Observation

/// The menu bar item: a flame when idle, live tokens/sec while generating.
/// Click opens MenuPanel in a panel under the item.
@MainActor
final class StatusItemController: NSObject {
    private let model: AppModel
    private let item: NSStatusItem
    private var panel: PanelWindow!

    init(model: AppModel) {
        self.model = model
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        item.autosaveName = "HearthStatusItem"
        if let button = item.button {
            button.target = self
            button.action = #selector(toggle(_:))
            button.imagePosition = .imageLeading
            let size = NSFont.menuBarFont(ofSize: 0).pointSize
            button.font = .monospacedDigitSystemFont(ofSize: size, weight: .regular)
            button.toolTip = "Hearth"
        }

        panel = PanelWindow(content: MenuPanel().environment(model))

        observe()
    }

    func closePanel() {
        panel.dismiss()
    }

    @objc private func toggle(_ sender: Any?) {
        if panel.isShown {
            panel.dismiss()
        } else if let button = item.button {
            panel.show(below: button)
        }
    }

    /// Re-renders whenever anything the label reads changes.
    private func observe() {
        withObservationTracking {
            render()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    private func render() {
        guard let button = item.button else { return }
        let stats = model.stats
        var title = ""
        let symbol: String
        if stats.isGenerating || stats.currentRate > 0 {
            symbol = "flame.fill"
            title = " \(Int(stats.currentRate.rounded())) tok/s"
        } else if model.models.state.isBusy {
            symbol = "arrow.down.circle"
        } else {
            // Paused: the same flame, dimmed. (There's no "flame.slash" symbol; it left the item blank.)
            symbol = "flame"
        }
        button.appearsDisabled = !(model.server.isRunning || model.needsSetup || stats.isGenerating)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Hearth")
        // A coding agent needs the user (permission, or its turn): a dot on the flame.
        let needsUser = model.agents.isEnabled && model.agents.needsUser
        button.image = needsUser ? image.map(Self.withDot) : image
        button.image?.isTemplate = true
        button.image?.accessibilityDescription = needsUser ? "Hearth, an agent needs you" : "Hearth"
        button.toolTip = model.agents.needsUser ? "Hearth: an agent needs you" : "Hearth"
        button.title = title
    }

    /// The symbol with a small filled dot at its top right; stays a template image (menu bar colours).
    private static func withDot(_ base: NSImage) -> NSImage {
        let size = NSSize(width: base.size.width + 3, height: base.size.height)
        return NSImage(size: size, flipped: false) { rect in
            base.draw(in: NSRect(x: 0, y: 0, width: base.size.width, height: base.size.height))
            let d: CGFloat = 6
            let dot = NSRect(x: rect.maxX - d, y: rect.maxY - d, width: d, height: d)
            NSColor.black.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
    }
}
