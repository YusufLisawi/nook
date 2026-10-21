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
    func enabled(_ id: String) -> Bool {
        if id == "launcher" || id == "smartAnswers" {
            guard Services.shared.plugins.tabs.contains(where: { $0.id == "launcher" }), all.contains(where: { $0.id == "plugin:launcher" }), lifecycle.enabled("plugin:launcher") else { return false }
            if id == "smartAnswers", let tab = Services.shared.plugins.tabs.first(where: { $0.id == "launcher" }) { return PluginSettingsStore.values(for: tab)["smartAnswers"]?.bool ?? true }
            return true
        }
        return lifecycle.enabled(id)
    }
    func tabEnabled(_ id: String) -> Bool {
        !lifecycle.disabledTabs.contains(id) && all.filter { $0.tabs.contains(id) }.allSatisfy { enabled($0.id) }
    }
    func set(_ id: String, _ on: Bool) {
        lifecycle.set(id, enabled: on); changed()
    }
    func setTab(_ id: String, _ on: Bool) {
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
        add("pluginStore", "Plugin Store", "Browse and install community plugins.", "Checks defaults and updates daily while on.", start: { PluginStore.register() }, stop: { PluginStore.disable(); Self.unregister("", panes: ["plugin-store"]) })
        add("keyboard", "Keyboard & Open Nook", "Command palette and global Open Nook shortcut.", "One shared shortcut tap, only when needed.", start: { KeyboardActions.shared.start(); NativeShortcutIntegration.register() }, stop: { KeyboardActions.shared.stop(); ShortcutRegistry.unregister(prefix: "keyboard."); ShortcutRegistry.unregister(prefix: "navigation.") })
        BridgeRegistry.register("features", functions: ["list"]) { [weak self] _, _, _, reply in
            reply(self?.payload ?? [], nil)
        }

        ShortcutRegistry.externalConflicts = SystemShortcutConflicts.systemConflicts
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
            let id = "plugin:" + tab.id
            if ["file-search", "clips", "windows", "launcher"].contains(tab.id), UserDefaults.standard.object(forKey: FeatureLifecycle.key(id)) == nil {
                UserDefaults.standard.set(false, forKey: FeatureLifecycle.key(id))
            }
            if UserDefaults.standard.object(forKey: FeatureLifecycle.key(id)) == nil,
               let previous = UserDefaults.standard.object(forKey: FeatureLifecycle.key(tab.id)) as? Bool {
                UserDefaults.standard.set(previous, forKey: FeatureLifecycle.key(id))
            }
            lifecycle.register(Feature(id: id, title: tab.name, summary: "Store or Developer plugin.",
                                       memoryNote: "Turning off stops its helper and releases its page.",
                                       defaultEnabled: !FeatureLifecycle.raycastIDs.contains(tab.id), tabs: [tab.id]))
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
            (enabled("commands") && s.commands.commands.contains { $0.enabled && $0.hotkey != nil }) ||
            tabs || groups
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
        if ["clips", "files", "windows"].contains(ns) { return false }
        return owners[ns].map(enabled) ?? true
    }
    func paneEnabled(_ id: String) -> Bool {
        let owners = ["commands": "commands", "dictation": "dictation", "agents": "agents", "plugin-store": "pluginStore"]
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
