import AppKit
import Combine

final class WindowShortcuts: ObservableObject {
    static let shared = WindowShortcuts()
    static let storageKey = "windowManagementShortcuts"
    static let almostScaleKey = "windowManagementAlmostScale"
    private var observer: AnyCancellable?

    private init() {
        observer = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }

    func all() -> [String: TabHotkey] {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey) else { return [:] }
        return (try? JSONDecoder().decode([String: TabHotkey].self, from: data)) ?? [:]
    }

    func get(_ action: WindowAction) -> TabHotkey? { all()[action.rawValue] }

    func set(_ action: WindowAction, _ hotkey: TabHotkey?) {
        objectWillChange.send()
        var values = all()
        values[action.rawValue] = hotkey
        UserDefaults.standard.set(try? JSONEncoder().encode(values), forKey: Self.storageKey)
        PluginEvents.emit("windows", NSNull()) // each notch reloads its own captured target
    }

    func action(key: Int64, modifiers: CGEventFlags) -> WindowAction? {
        let values = all()
        guard let action = WindowAction.allCases.first(where: {
            values[$0.rawValue]?.keyCode == Int(key) && values[$0.rawValue]?.modifiers == modifiers.rawValue
        }), let hotkey = values[action.rawValue], conflicts(hotkey, for: action).isEmpty else { return nil }
        return action
    }

    /// Hard conflicts are never run or newly saved. Existing conflicts remain visible so users can fix them.
    func conflicts(_ hotkey: TabHotkey, for action: WindowAction) -> [String] {
        func matches(_ other: TabHotkey?) -> Bool {
            other?.keyCode == hotkey.keyCode && other?.modifiers == hotkey.modifiers
        }
        var conflicts = WindowAction.allCases.filter { $0 != action && matches(get($0)) }.map(\.title)
        conflicts += TabHotkeys.all().filter { matches($0.value) }.map { "\($0.key) tab" }.sorted()
        conflicts += Services.shared.commands.commands.filter { $0.enabled && matches($0.hotkey) }.map { "AI Command: \($0.name)" }
        let monitor = Services.shared.dictation.hotkeys
        for (name, shortcut) in [("Dictation hold", monitor.hold), ("Dictation toggle", monitor.toggle)] {
            if let shortcut, shortcut.keyCode == hotkey.keyCode, shortcut.modifiers == hotkey.modifiers { conflicts.append(name) }
        }
        conflicts += Self.systemConflicts(hotkey)
        return conflicts
    }

    static func systemConflicts(_ hotkey: TabHotkey) -> [String] {
        let flags = CGEventFlags(rawValue: hotkey.modifiers)
        // These app/system shortcuts are not represented in AppleSymbolicHotKeys.
        let reserved: [(Int, CGEventFlags, String)] = [
            (48, .maskCommand, "Switch Applications"), (48, [.maskCommand, .maskShift], "Switch Applications"),
            (12, .maskCommand, "Quit"), (13, .maskCommand, "Close Window"),
            (53, [.maskAlternate, .maskCommand], "Force Quit"), (12, [.maskControl, .maskCommand], "Lock Screen")
        ]
        var result = reserved.filter { $0.0 == hotkey.keyCode && $0.1 == flags }.map { "macOS: \($0.2)" }
        let entries = UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys") ?? [:]
        var seen = Set<String>()
        for (id, value) in entries {
            guard let entry = value as? [String: Any], entry["enabled"] as? Bool == true,
                  let spec = entry["value"] as? [String: Any], spec["type"] as? String == "standard",
                  let params = spec["parameters"] as? [NSNumber], params.count >= 3,
                  params[1].intValue == hotkey.keyCode,
                  CGEventFlags(rawValue: params[2].uint64Value).intersection(TabHotkeys.relevant) == flags else { continue }
            seen.insert(id)
        }
        // macOS omits uncustomized entries from the plist. Cover the usual defaults as well.
        let defaults: [(String, Int, CGEventFlags, String)] = [
            ("64", 49, .maskCommand, "Spotlight"), ("60", 49, .maskControl, "Input Source"),
            ("79", 123, .maskControl, "Previous Space"), ("81", 124, .maskControl, "Next Space"),
            ("32", 126, .maskControl, "Mission Control"), ("33", 125, .maskControl, "Application Windows")
        ]
        for (id, key, mods, title) in defaults where key == hotkey.keyCode && mods == flags && entries[id] == nil {
            result.append("macOS: \(title)")
        }
        if !seen.isEmpty { result.append("macOS Keyboard Shortcuts (\(seen.sorted().joined(separator: ", ")))") }
        return result
    }

    func holdWarning(_ hotkey: TabHotkey) -> String? {
        guard let hold = Services.shared.dictation.hotkeys.hold, hold.keyCode == nil,
              CGEventFlags(rawValue: hotkey.modifiers).isSuperset(of: hold.flags) else { return nil }
        return "Pressing this shortcut cancels the \(hold.display) dictation hold."
    }
}
