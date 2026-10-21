import AppKit
import SwiftUI

/// Creates Settings on demand; closing releases its hosting tree and pane-specific work.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let onScreensChanged: () -> Void

    init(onScreensChanged: @escaping () -> Void) { self.onScreensChanged = onScreensChanged; super.init() }

    func windowWillClose(_ notification: Notification) {
        window?.contentViewController = nil
        window = nil
    }

    func show(pane: String?) {
        Task { @MainActor in await PluginAutomaticUpdates.shared.check(settingsOpened: true) }
        if let pane, SettingsRouter.isKnown(pane) { SettingsRouter.shared.pane = Features.shared.paneEnabled(pane) ? pane : "features" }
        prepare()
        NSApp.activate(ignoringOtherApps: true)
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
    }

    private func prepare() {
        guard window == nil else { return }
        let host = NSHostingController(rootView: SettingsView(onScreensChanged: onScreensChanged))
        let window = NSWindow(contentViewController: host)
        window.delegate = self
        window.title = "Nook Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .automatic
        window.setContentSize(NSSize(width: 1080, height: 680))
        window.minSize = NSSize(width: 980, height: 600)
        window.isReleasedWhenClosed = false
        let restored = window.setFrameUsingName("NookSettings")
        if !restored || !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(window.frame) }) { window.center() }
        window.setFrameAutosaveName("NookSettings")
        self.window = window
        // Force SwiftUI's initial layout without ordering or activating the window.
        host.view.layoutSubtreeIfNeeded()
    }
}
