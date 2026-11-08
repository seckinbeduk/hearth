import AppKit
import SwiftUI

/// The panel under the menu bar item, as a borderless floating panel instead of an NSPopover.
/// It closes on a click anywhere outside it (other apps, the desktop) and on Esc, whether or not
/// macOS let Hearth become the active app.
@MainActor
final class PanelWindow: NSPanel {
    private var outsideClicks: Any?
    private var resizeObserver: NSObjectProtocol?
    private weak var anchor: NSStatusBarButton?

    init(content: some View) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 340, height: 400),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true

        let hosting = NSHostingView(rootView: AnyView(content))
        // Min and max too, so the window follows the content while it's open (rows come and go).
        hosting.sizingOptions = [.intrinsicContentSize, .minSize, .maxSize]
        hosting.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: effect.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        contentView = effect

        // Keep the top edge under the menu bar item when the content grows or shrinks.
        resizeObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: self,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    var isShown: Bool { isVisible }

    func show(below button: NSStatusBarButton) {
        anchor = button
        if let size = contentView?.fittingSize, size.width > 0 { setContentSize(size) }
        place()
        makeKeyAndOrderFront(nil)
        NSApp.activate()
        watchOutsideClicks()
    }

    func dismiss() {
        stopWatchingOutsideClicks()
        guard isVisible else { return }
        orderOut(nil)
    }

    /// Esc closes it, like a menu.
    override func cancelOperation(_ sender: Any?) { dismiss() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { dismiss() } else { super.keyDown(with: event) }
    }

    private func place() {
        guard let button = anchor, let buttonWindow = button.window, let screen = buttonWindow.screen ?? NSScreen.main
        else { return }
        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        var origin = NSPoint(x: buttonFrame.midX - frame.width / 2, y: buttonFrame.minY - frame.height - 4)
        let visible = screen.visibleFrame
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - frame.width - 8)
        if frame.origin != origin { setFrameOrigin(origin) }
    }

    private func watchOutsideClicks() {
        guard outsideClicks == nil else { return }
        // Clicks in other apps and on the desktop. Clicks inside Hearth (the panel, the menu bar item)
        // go to Hearth itself and are handled there.
        outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) {
            [weak self] _ in
            Task { @MainActor in self?.dismiss() }
        }
    }

    private func stopWatchingOutsideClicks() {
        if let outsideClicks { NSEvent.removeMonitor(outsideClicks) }
        outsideClicks = nil
    }
}
