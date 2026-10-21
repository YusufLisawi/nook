import AppKit
import SwiftUI

/// A dictation shortcut: modifiers only (e.g. ⌃⌥, fn) when `keyCode` is nil, otherwise modifiers + key.
struct DictationShortcut: Codable, Equatable {
    var keyCode: Int?
    var modifiers: UInt64
    var display: String

    var flags: CGEventFlags { CGEventFlags(rawValue: modifiers) }

    static let defaultHold = DictationShortcut(keyCode: nil, modifiers: CGEventFlags([.maskControl, .maskAlternate]).rawValue, display: "⌃⌥")
    static let defaultToggle = DictationShortcut(keyCode: 49, modifiers: CGEventFlags.maskAlternate.rawValue, display: "⌥Space")

    /// Never set → default. Saved as empty data → turned off.
    static func load(_ key: String, fallback: DictationShortcut) -> DictationShortcut? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return fallback }
        return data.isEmpty ? nil : try? JSONDecoder().decode(DictationShortcut.self, from: data)
    }

    static func save(_ key: String, _ shortcut: DictationShortcut?) {
        UserDefaults.standard.set(shortcut.flatMap { try? JSONEncoder().encode($0) } ?? Data(), forKey: key)
    }
}

enum Modifiers {
    static let all: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand, .maskSecondaryFn]

    static func from(_ flags: NSEvent.ModifierFlags) -> CGEventFlags {
        var out: CGEventFlags = []
        if flags.contains(.control) { out.insert(.maskControl) }
        if flags.contains(.option) { out.insert(.maskAlternate) }
        if flags.contains(.shift) { out.insert(.maskShift) }
        if flags.contains(.command) { out.insert(.maskCommand) }
        if flags.contains(.function) { out.insert(.maskSecondaryFn) }
        return out
    }

    static func symbols(_ flags: CGEventFlags) -> String {
        var s = ""
        if flags.contains(.maskSecondaryFn) { s += "fn" }
        if flags.contains(.maskControl) { s += "⌃" }
        if flags.contains(.maskAlternate) { s += "⌥" }
        if flags.contains(.maskShift) { s += "⇧" }
        if flags.contains(.maskCommand) { s += "⌘" }
        return s
    }

    static func keyName(_ event: NSEvent) -> String {
        let names: [UInt16: String] = [49: "Space", 36: "↩", 48: "⇥", 123: "←", 124: "→", 125: "↓", 126: "↑",
                                       122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
                                       101: "F9", 109: "F10", 103: "F11", 111: "F12"]
        return names[event.keyCode] ?? (event.charactersIgnoringModifiers ?? "?").uppercased()
    }
}
