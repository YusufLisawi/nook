import AppKit
import SwiftUI

enum OpenNookShortcut {
    // ⌘Space is Spotlight; ⌥⌘Space is Finder search (symbolic hotkeys 64/65).
    static let defaultShortcut: TabHotkey = {
        let candidates: [(CGEventFlags, String)] = [
            ([.maskAlternate, .maskShift, .maskCommand], "⌥⇧⌘Space"),
            ([.maskControl, .maskShift, .maskCommand], "⌃⇧⌘Space"),
            ([.maskControl, .maskAlternate, .maskShift, .maskCommand], "⌃⌥⇧⌘Space"),
        ]
        let hotkeys = UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys") ?? [:]
        for (flags, label) in candidates {
            let conflict = hotkeys.values.contains { raw in
                guard let item = raw as? [String: Any], (item["enabled"] as? NSNumber)?.boolValue == true,
                      let value = item["value"] as? [String: Any], let parameters = value["parameters"] as? [NSNumber], parameters.count == 3 else { return false }
                return parameters[1].intValue == 49 && parameters[2].uint64Value == flags.rawValue
            }
            if !conflict { return TabHotkey(keyCode: 49, modifiers: flags.rawValue, display: label) }
        }
        return TabHotkey(keyCode: 49, modifiers: candidates[0].0.rawValue, display: candidates[0].1)
    }()

    static var current: TabHotkey? {
        guard let data = UserDefaults.standard.data(forKey: Prefs.openNookShortcut) else { return defaultShortcut }
        return data.isEmpty ? nil : try? JSONDecoder().decode(TabHotkey.self, from: data)
    }

    static func save(_ shortcut: TabHotkey?) {
        UserDefaults.standard.set(shortcut.flatMap { try? JSONEncoder().encode($0) } ?? Data(), forKey: Prefs.openNookShortcut)
    }

    static func matches(key: Int64, modifiers: CGEventFlags) -> Bool {
        guard let current else { return false }
        return current.keyCode == key && current.modifiers == modifiers.rawValue
    }
}

/// General and Keyboard Shortcuts share the same recorder and conflict catalog.
struct OpenNookShortcutRow: View {
    var body: some View {
        if let registration = ShortcutRegistry.shortcuts.first(where: { $0.id == "keyboard.openNook" }) {
            LabeledContent("Open Nook") {
                SettingsShortcutRecorder(item: .registration(registration))
            }
            .help("Open Nook from any app. Escape cancels; Delete turns it off.")
        }
    }
}
