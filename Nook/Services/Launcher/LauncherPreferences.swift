import AppKit
import SwiftUI

enum LauncherPreferences {
    static let shortcutKey = "launcher.shortcut"
    static let sourcesKey = "launcher.sources"
    static let historyKey = "launcher.history"

    static var sources: Set<LauncherSource> {
        guard let values = UserDefaults.standard.stringArray(forKey: sourcesKey) else { return Set(LauncherSource.allCases) }
        return Set(values.compactMap(LauncherSource.init(rawValue:)))
    }
    static func set(_ source: LauncherSource, enabled: Bool) {
        var values = sources
        if enabled { values.insert(source) } else { values.remove(source) }
        UserDefaults.standard.set(values.map(\.rawValue).sorted(), forKey: sourcesKey)
    }
}

enum LauncherShortcut {
    static var defaultShortcut: TabHotkey? {
        let candidates: [(CGEventFlags, String)] = [(.maskAlternate, "⌥Space"), ([.maskControl, .maskAlternate], "⌃⌥Space")]
        for (flags, title) in candidates {
            let key = TabHotkey(keyCode: 49, modifiers: flags.rawValue, display: title)
            func same(_ value: TabHotkey?) -> Bool { value?.keyCode == key.keyCode && value?.modifiers == key.modifiers }
            let used = ShortcutRegistry.shortcuts.contains { $0.id != "launcher.toggle" && same($0.get()) }
                || TabHotkeys.all().values.contains(where: { same($0) })
                || Services.shared.commands.commands.contains { same($0.hotkey) }
                || TabNavigationStore.shared.groups.contains { same($0.hotkey) }
                || [DictationShortcut.load(DictationService.Keys.holdShortcut, fallback: .defaultHold),
                    DictationShortcut.load(DictationService.Keys.toggleShortcut, fallback: .defaultToggle)].compactMap { $0 }.contains {
                    $0.keyCode == key.keyCode && $0.modifiers == key.modifiers
                }
            if !used && WindowShortcuts.systemConflicts(key).isEmpty { return key }
        }
        return nil // Don't steal another assigned shortcut if both defaults are occupied.
    }
    static var current: TabHotkey? {
        guard let data = UserDefaults.standard.data(forKey: LauncherPreferences.shortcutKey) else { return defaultShortcut }
        return data.isEmpty ? nil : try? JSONDecoder().decode(TabHotkey.self, from: data)
    }
    static func save(_ value: TabHotkey?) {
        UserDefaults.standard.set(value.flatMap { try? JSONEncoder().encode($0) } ?? Data(), forKey: LauncherPreferences.shortcutKey)
    }
    static func matches(key: Int64, modifiers: CGEventFlags) -> Bool {
        guard let current else { return false }
        return current.keyCode == Int(key) && current.modifiers == modifiers.rawValue
    }
}

struct LauncherSettingsPane: View {
    @ObservedObject private var feature = LauncherFeature.shared
    @State private var revision = 0

    var body: some View {
        Form {
            Section("Launcher") {
                if let shortcut = ShortcutRegistry.shortcuts.first(where: { $0.id == "launcher.toggle" }) {
                    LabeledContent("Toggle Launcher") { SettingsShortcutRecorder(item: .registration(shortcut)) }
                }
                Text("Open a borderless search bar in the notch. Search apps, AI commands, plugins and actions.")
                    .foregroundStyle(.secondary)
            }
            Section("Sources") {
                ForEach(LauncherSource.allCases, id: \.self) { source in
                    Toggle(source.title, isOn: Binding(get: { let _ = revision; return LauncherPreferences.sources.contains(source) },
                                                       set: { LauncherPreferences.set(source, enabled: $0); revision += 1 }))
                }
            }
            Section("Recent Items") {
                LabeledContent("Saved launches", value: "\(feature.history.count)")
                Button("Clear Recents") { feature.clearHistory() }.disabled(feature.history.isEmpty)
                Text("Launch counts and last-used dates stay on this Mac. Quick AI queries and selected text are never saved in recents.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Keyboard") {
                Text("↑↓ or ⌃N/⌃P to choose · Return to open · ⌘Return for the alternate action · ⌘K for actions · Tab for Quick AI · ⌘1–9 to pick. Escape clears your search, then closes.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .focusEffectDisabled()
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in revision += 1 }
    }
}
