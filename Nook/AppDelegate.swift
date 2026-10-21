import AppKit
import Sparkle
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var controllers: [NotchController] = []
    /// Sparkle: checks nook.motkan.com/appcast.xml daily; updates are EdDSA-signed + notarized.
    let updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.registerDefaults()
        Services.shared.start()
        rebuildNotches()
        Services.shared.dictation.hotkeys.onShortcut = { [weak self] key, mods in
            if Services.shared.commands.handleShortcut(key: key, modifiers: mods) { return true } // AI command hotkeys
            guard let self, let tab = TabHotkeys.tab(forKey: key, modifiers: mods) else { return false }
            DispatchQueue.main.async { self.notchUnderMouse()?.viewModel.toggle(tab: tab) }
            return true
        }
        Services.shared.commands.closeNotches = { [weak self] in self?.controllers.forEach { $0.viewModel.close() } }
        Services.shared.commands.openTab = { [weak self] tab in self?.notchUnderMouse()?.viewModel.open(tab: tab) }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.rebuildNotches()
        }
        setupStatusItem()
        setupEditMenu()
        handleTerminationSignals()
        ToolsInstaller.installIfNeeded()
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

    /// nook://open/<tab> · nook://toggle/<tab> · nook://close · nook://reload · nook://settings · nook://check-updates  (used by the `nook` CLI)
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "nook" {
            let tab = url.pathComponents.dropFirst().first
            switch url.host {
            case "open": notchUnderMouse()?.viewModel.open(tab: tab)
            case "toggle":
                if let tab { notchUnderMouse()?.viewModel.toggle(tab: tab) }
            case "close": controllers.forEach { $0.viewModel.close() }
            case "reload": Services.shared.plugins.reload(); Services.shared.plugins.touch()
            case "settings": showSettings(pane: tab)
            case "install": PluginStore.shared.open(tab)
            case "check-updates": updater.checkForUpdates(nil)
            default: break
            }
        }
    }

    /// `kill`/`pkill` skip applicationWillTerminate. Without this the Mac stays pointed at a closed proxy port (no internet).
    private var signalSources: [DispatchSourceSignal] = []
    private func handleTerminationSignals() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                Services.shared.shutdown()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
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
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        menu.addItem(withTitle: "Nook \(version)", action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open Nook", action: #selector(openNotch), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Check for Updates…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "").target = updater
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

    @objc func openSettings() { showSettings(pane: nil) }

    /// Opens (or brings back) the Settings window, optionally on a pane ("commands", "ai", …).
    func showSettings(pane: String?) {
        if let pane, SettingsPane(rawValue: pane) != nil || SettingsRegistry.panes.contains(where: { $0.id == pane }) {
            SettingsRouter.shared.pane = pane
        }
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(onScreensChanged: { [weak self] in self?.rebuildNotches() })))
            window.title = "Nook Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.toolbarStyle = .unified
            window.titlebarSeparatorStyle = .automatic
            window.setContentSize(NSSize(width: 820, height: 600))
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
