import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controllers: [NotchController] = []
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.registerDefaults()
        Services.shared.start()
        rebuildNotches()
        Services.shared.dictation.hotkeys.onShortcut = { [weak self] key, mods in
            guard let self, let tab = TabHotkeys.tab(forKey: key, modifiers: mods) else { return false }
            DispatchQueue.main.async { self.notchUnderMouse()?.viewModel.toggle(tab: tab) }
            return true
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.rebuildNotches()
        }
        setupStatusItem()
    }

    func applicationWillTerminate(_ notification: Notification) {
        Services.shared.shutdown()
    }

    /// One notch per target screen; reuses controllers when screens stay the same.
    func rebuildNotches() {
        let screens = NotchGeometry.targetScreens(setting: UserDefaults.standard.string(forKey: Prefs.preferredScreen))
        while controllers.count > screens.count { controllers.removeLast().stop() }
        for (i, screen) in screens.enumerated() {
            if i < controllers.count {
                controllers[i].update(screen: screen)
            } else {
                let controller = NotchController(screen: screen)
                controller.start()
                controllers.append(controller)
            }
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: "Nook")
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Nook", action: #selector(openNotch), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Nook", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    @objc private func openNotch() { notchUnderMouse()?.viewModel.open() }

    private func notchUnderMouse() -> NotchController? {
        let mouse = NSEvent.mouseLocation
        return controllers.first { $0.viewModel.geometry.screen.frame.contains(mouse) } ?? controllers.first
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(onScreensChanged: { [weak self] in self?.rebuildNotches() })))
            window.title = "Nook Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        settingsWindow?.center()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
