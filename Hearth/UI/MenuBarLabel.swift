import AppKit
import SwiftUI
import Observation

/// The menu bar item: a flame when idle, live tokens/sec while generating.
/// Click opens MenuPanel in a popover.
@MainActor
final class StatusItemController: NSObject {
    private let model: AppModel
    private let item: NSStatusItem
    private let popover = NSPopover()

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

        let hosting = NSHostingController(rootView: MenuPanel().environment(model))
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.animates = true

        observe()
    }

    func closePopover() {
        if popover.isShown { popover.performClose(nil) }
    }

    @objc private func toggle(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else if let button = item.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate()
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
        } else if model.server.isRunning || model.needsSetup {
            symbol = "flame"
        } else {
            symbol = "flame.slash"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Hearth")
        image?.isTemplate = true
        button.image = image
        button.title = title
    }
}
