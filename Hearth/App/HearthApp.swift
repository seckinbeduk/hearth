import SwiftUI
import AppKit

@main
struct HearthApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // The menu bar item and the main window are managed by AppDelegate (AppKit),
        // which is more reliable for a live-updating status item than MenuBarExtra.
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var statusItem: StatusItemController?
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if let index = CommandLine.arguments.firstIndex(of: AgentSummaryCheck.flag) {
            let folder = CommandLine.arguments.dropFirst(index + 1).first.map { URL(fileURLWithPath: $0) }
            Task {
                await AgentSummaryCheck.run(fixtures: folder)
                exit(0)
            }
            return
        }
        #endif
        model.showMainWindow = { [weak self] in self?.showMainWindow() }
        statusItem = StatusItemController(model: model)
        model.closePanel = { [weak self] in self?.statusItem?.closePopover() }

        if model.needsSetup { showMainWindow() }
        Task { await model.launch() }
    }

    /// Opening Hearth again (Finder, Spotlight, Dock) brings up the window,
    /// so it's reachable even if the menu bar item is hidden behind the notch.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func showMainWindow() {
        if window == nil {
            let root = RootView()
                .environment(model)
                .frame(minWidth: 760, minHeight: 600)
            let window = NSWindow(contentViewController: NSHostingController(rootView: root))
            window.title = "Hearth"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 860, height: 720))
            window.isReleasedWhenClosed = false
            window.center()
            window.setFrameAutosaveName("HearthMainWindow")
            self.window = window
        }
        statusItem?.closePopover()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}
