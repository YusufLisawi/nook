import AppKit
import SwiftUI

/// The single owner of optional services and their UI/bridge registrations. Main-thread confined.
final class Features: ObservableObject, @unchecked Sendable { // mutable state is confined to the main queue
    static let shared = Features()
    let lifecycle = FeatureLifecycle(defaults: .standard)
    private var observer: NSObjectProtocol?
    private var shortcutsObserver: NSObjectProtocol?
    private var started = false
    var all: [Feature] { lifecycle.features }
    func enabled(_ id: String) -> Bool { lifecycle.enabled(id) }
    func tabEnabled(_ id: String) -> Bool {
        !lifecycle.disabledTabs.contains(id) && all.filter { $0.tabs.contains(id) }.allSatisfy { enabled($0.id) || $0.tabs == ["clips"] && clipsEnabled }
    }
    private var clipsEnabled: Bool { enabled("clipboard") || enabled("screenshots") }
    func set(_ id: String, _ on: Bool) {
        if id == "clipboard" { UserDefaults.standard.set(on, forKey: ClipPreferences.enabled) }
        lifecycle.set(id, enabled: on); changed()
    }
    func setTab(_ id: String, _ on: Bool) {
        if id == "clips" { UserDefaults.standard.set(on, forKey: ClipPreferences.enabled) }
        lifecycle.setTab(id, enabled: on); changed()
    }

    @MainActor func start(_ s: Services) {
        guard !started else { return }; started = true
        func add(_ id: String, _ title: String, _ summary: String, _ memory: String = "Released when off.", tabs: [String] = [], dependencies: [String] = [], start: @escaping () -> Void = {}, stop: @escaping () -> Void = {}) {
            lifecycle.register(Feature(id: id, title: title, summary: summary, memoryNote: memory,
                                       defaultEnabled: !FeatureLifecycle.raycastIDs.contains(id), tabs: tabs, dependencies: dependencies, start: start, stop: stop))
        }
        add("home", "Home", "Quick actions in the notch.", "Web content exists only while visible.", tabs: ["home"])
        add("media", "Now Playing", "Music and Spotify controls and closed-notch activity.", tabs: ["media"], start: { s.media.start() }, stop: { s.release("media") { ($0 as? MediaController)?.stop() } })
        add("timers", "Timers", "Countdown, Pomodoro and stopwatch.", "No ticking until a timer runs.", tabs: ["timers"], stop: { s.release("timers") { ($0 as? TimerService)?.reset() } })
        add("shelf", "Shelf", "Temporary files and drag-and-drop.", tabs: ["shelf"], stop: { s.release("shelf") })
        add("scratch", "Scratch", "Native scratch pad.", "No background service.", tabs: ["scratch"])
        add("notes", "Notes", "Persistent notes in the notch.", "Web content exists only while visible.", tabs: ["notes"])
        add("proxy", "Proxy", "Manage and connect system proxies.", tabs: ["proxy"], start: { s.proxy.restoreOnLaunch() }, stop: { s.release("proxy") { ($0 as? ProxyService)?.shutdown() } })
        add("dictation", "Dictation", "Hold or toggle to transcribe speech.", tabs: ["dictation"], start: { s.dictation.start() }, stop: { s.release("dictation") { ($0 as? DictationService)?.stop() } })
        add("mixer", "Mixer", "Device controls and per-app volume.", tabs: ["mixer"], start: { s.audio.start() }, stop: { s.release("audio") { ($0 as? AudioMixer)?.shutdown() } })
        add("links", "Link Catcher", "Save copied links to Links.", "Checks clipboard changes every 2 seconds when on.", tabs: ["links"], start: { s.links.start() }, stop: { s.release("links") { ($0 as? LinkCatcher)?.stop() } })
        add("commands", "AI Commands", "Run saved prompts on selections and clipboard text.", tabs: ["commands"], start: { _ = s.commands }, stop: { s.release("commands") { ($0 as? AICommands)?.stop() } })
        add("agents", "Agents", "Codex chats and background tasks.", tabs: ["agents"], start: { AgentService.register() }, stop: { AgentService.disable(); Self.unregister("agents", panes: ["agents"]) })
        add("monitor", "Monitor", "CPU, memory, network and battery stats.", "Samples only while the tab is visible.", tabs: ["monitor"], stop: { s.release("system") })
        add("teleprompter", "Teleprompter", "Scrolling script display.", "No background service.", tabs: ["teleprompter"])
        add("cleaner", "Cleaner", "Review and trash disposable files.", "Runs only on request.", tabs: ["cleaner"], start: { CleanerBridge.register() }, stop: { CleanerBridge.stop() })
        add("pluginStore", "Plugin Store", "Browse and install community plugins.", "No network request until opened.", start: { PluginStore.register() }, stop: { PluginStore.disable(); Self.unregister("", panes: ["plugin-store"]) })
        add("keyboard", "Keyboard & Open Nook", "Command palette and global Open Nook shortcut.", "One shared shortcut tap, only when needed.", start: { KeyboardActions.shared.start(); NativeShortcutIntegration.register() }, stop: { KeyboardActions.shared.stop(); ShortcutRegistry.unregister(prefix: "keyboard."); ShortcutRegistry.unregister(prefix: "navigation.") })
        add("windows", "Window Management", "Position windows with Accessibility and shortcuts.", tabs: ["windows"], start: { WindowManager.shared.start(); NativeShortcutIntegration.registerWindows() }, stop: { WindowManager.disable(); Self.unregister("windows", panes: ["windows"]); ShortcutRegistry.unregister(prefix: "windows.") })
        add("files", "File Search", "Filename index, folder watcher and Spotlight fallback.", "Off releases the packed index and query cursors.", tabs: ["files"], start: { FileSearchService.shared.register() }, stop: { FileSearchService.disable(); Self.unregister("files", panes: ["files"]) })
        add("clipboard", "Clipboard History", "Save clipboard text, images and files.", "Off releases history, thumbnails and polling.", tabs: ["clips"], start: { ClipboardHistory.shared.start(); ClipsFeature.start() }, stop: { ClipboardHistory.disable(); ClipsThumbnails.shared.clear(); ClipsFeature.reconcile() })
        add("screenshots", "Screenshots & Recordings", "Watch the capture folder and recognize screenshot text.", "Off closes the folder watcher and drops OCR/cache state.", tabs: ["clips"], start: { CaptureFeatureSettings.register(); ClipsFeature.start(); ScreenCaptureIndex.shared.start(directory: Services.supportDir.appendingPathComponent("Clips"), accessAllowed: { FileSearchAccessPolicy.current().allows($0.path) }) }, stop: { ScreenCaptureIndex.disable(); ClipsThumbnails.shared.clear(); SettingsRegistry.unregister("screenshots"); ClipsFeature.reconcile() })
        add("mouse", "Mouse", "Wheel smoothing and extra button mappings.", tabs: ["mouse"], start: { s.mouse.registerBridge(); s.mouse.start() }, stop: { s.release("mouse") { ($0 as? MouseFixService)?.shutdown() }; Self.unregister("mouse") })
        add("launcher", "Launcher", "Search applications, commands and plugins.", "Off drops app metadata, icons, Spotlight and FSEvents.", start: { LauncherFeature.start() }, stop: { LauncherFeature.stop(); Self.unregister("", panes: ["launcher"]); ShortcutRegistry.unregister(prefix: "launcher.") })
        add("smartAnswers", "Smart Answers", "Local calculator, conversions and other launcher answers.", dependencies: ["launcher"], stop: { LauncherAnswers.disable() })
        add("launcherFiles", "Launcher File Source", "Include files in launcher searches.", dependencies: ["launcher", "files"])
        BridgeRegistry.register("features", functions: ["list"]) { [weak self] _, _, _, reply in
            reply(self?.payload ?? [], nil)
        }

        ShortcutRegistry.externalConflicts = WindowShortcuts.systemConflicts
        lifecycle.migrate()
        SettingsRegistry.register(id: "features", title: "Features", symbol: "switch.2", tint: .blue, order: 0,
                                  keywords: ["enable", "disable", "memory", "battery", "Raycast"]) { FeaturesPane() }
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.lifecycle.reconcile(); self?.changed()
        }
        shortcutsObserver = NotificationCenter.default.addObserver(forName: .nookShortcutsChanged, object: nil, queue: .main) { [weak self] _ in self?.refreshHotkeys() }
        lifecycle.reconcile()
        changed()
    }
    func registerPlugins(_ tabs: [TabItem]) {
        for tab in tabs where !all.contains(where: { $0.tabs.contains(tab.id) }) {
            lifecycle.register(Feature(id: "plugin:" + tab.id, title: tab.name, summary: "Plugin tab.", memoryNote: "Web content exists only while visible.", tabs: [tab.id]))
        }
        lifecycle.reconcile()
        changed()
    }

    private static func unregister(_ namespace: String, panes: [String] = []) {
        BridgeRegistry.unregister(namespace)
        for pane in panes { SettingsRegistry.unregister(pane) }
    }
    var payload: [[String: Any]] { all.map { ["id": $0.id, "title": $0.title, "enabled": enabled($0.id)] } }

    private func changed() {
        LauncherFeature.reconfigure()
        PluginSettingsStore.releaseCaches(for: Set(all.flatMap(\.tabs).filter { !tabEnabled($0) }))
        objectWillChange.send()
        refreshHotkeys()
        NotificationCenter.default.post(name: .nookFeaturesChanged, object: nil)
        PluginEvents.emit("features", payload)
    }
    func refreshHotkeys() {
        guard started else { return }
        let s = Services.shared
        let tabs = TabHotkeys.all().keys.contains { id in tabEnabled(id) && s.plugins.tabs.contains { $0.id == id } }
        let groups = TabNavigationStore.shared.groups.contains { $0.hotkey != nil && $0.members.contains(where: tabEnabled) }
        let needed = (enabled("keyboard") && OpenNookShortcut.current != nil) || (enabled("dictation") && (s.hotkeys.hold != nil || s.hotkeys.toggle != nil)) ||
            (enabled("launcher") && LauncherShortcut.current != nil) || (enabled("commands") && s.commands.commands.contains { $0.enabled && $0.hotkey != nil }) ||
            (enabled("windows") && WindowAction.allCases.contains { WindowShortcuts.shared.get($0) != nil }) || tabs || groups
        if needed { s.hotkeys.start() } else { s.hotkeys.stop() }
    }
    func shutdown() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let shortcutsObserver { NotificationCenter.default.removeObserver(shortcutsObserver) }
        observer = nil; shortcutsObserver = nil
        lifecycle.shutdown(); Services.shared.hotkeys.stop()
    }
    func allowsBridge(_ fn: String) -> Bool {
        let ns = String(fn.split(separator: ".").first ?? "")
        let owners = ["files": "files", "windows": "windows", "agents": "agents", "commands": "commands", "dictation": "dictation", "audio": "mixer", "proxy": "proxy", "timer": "timers", "mouse": "mouse", "system": "monitor", "cleaner": "cleaner", "actions": "keyboard"]
        if ns == "clips" { return clipsEnabled }
        return owners[ns].map(enabled) ?? true
    }
    func paneEnabled(_ id: String) -> Bool {
        let owners = ["commands": "commands", "dictation": "dictation", "clipboard": "clipboard", "screenshots": "screenshots", "files": "files", "windows": "windows", "launcher": "launcher", "agents": "agents", "plugin-store": "pluginStore"]
        return owners[id].map(enabled) ?? true
    }
}

extension Notification.Name { static let nookFeaturesChanged = Notification.Name("nookFeaturesChanged") }

struct FeaturesPane: View {
    @ObservedObject private var features = Features.shared
    var body: some View {
        Form {
            Section {
                Text("Turn off features you use elsewhere. Turning one off stops its background work and releases its caches. Saved data and shortcuts return when enabled.")
                    .foregroundStyle(.secondary)
            }
            Section("Features") {
                ForEach(features.all, id: \.id) { feature in
                    Toggle(isOn: Binding(get: { features.lifecycle.requested(feature.id) }, set: { features.set(feature.id, $0) })) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(feature.title)
                            Text(feature.summary).font(.callout).foregroundStyle(.secondary)
                            Text(feature.memoryNote + (feature.dependencies.isEmpty ? "" : " Requires " + feature.dependencies.joined(separator: ", ") + "."))
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 3)
                    }
                }
            }
        }.formStyle(.grouped)
    }
}
