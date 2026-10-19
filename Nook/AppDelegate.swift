import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
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
        setupEditMenu()
    }

    /// Hidden main menu so ⌘A/⌘C/⌘V/⌘Z work in the Settings window (Nook has no visible menu bar).
    private func setupEditMenu() {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a")
        let main = NSMenu()
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        main.addItem(NSMenuItem(title: "Nook", action: nil, keyEquivalent: ""))
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    /// nook://open/<tab> · nook://toggle/<tab> · nook://close · nook://reload · nook://settings  (used by the `nook` CLI)
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "nook" {
            let tab = url.pathComponents.dropFirst().first
            switch url.host {
            case "open": notchUnderMouse()?.viewModel.open(tab: tab)
            case "toggle":
                if let tab { notchUnderMouse()?.viewModel.toggle(tab: tab) }
            case "close": controllers.forEach { $0.viewModel.close() }
            case "reload": Services.shared.plugins.reload(); Services.shared.plugins.touch()
            case "settings": openSettings()
            default: break
            }
        }
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
        menu.delegate = self
        menu.addItem(withTitle: "Open Nook", action: #selector(openNotch), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Nook", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    /// Shortcuts + dictation need Accessibility; show a fix-it item when it's off.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let tag = 42
        menu.item(withTag: tag).map(menu.removeItem)
        guard !AXIsProcessTrusted() else { return }
        let item = NSMenuItem(title: "⚠︎ Allow Accessibility for shortcuts…", action: #selector(openAccessibility), keyEquivalent: "")
        item.target = self
        item.tag = tag
        menu.insertItem(item, at: 0)
    }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
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
