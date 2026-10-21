import AppKit

enum SystemShortcutConflicts {
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
            ("65", 49, [.maskAlternate, .maskCommand], "Finder Search"),
            ("79", 123, .maskControl, "Previous Space"), ("81", 124, .maskControl, "Next Space"),
            ("32", 126, .maskControl, "Mission Control"), ("33", 125, .maskControl, "Application Windows")
        ]
        for (id, key, mods, title) in defaults where key == hotkey.keyCode && mods == flags && entries[id] == nil {
            result.append("macOS: \(title)")
        }
        if !seen.isEmpty { result.append("macOS Keyboard Shortcuts (\(seen.sorted().joined(separator: ", ")))") }
        return result
    }

}
