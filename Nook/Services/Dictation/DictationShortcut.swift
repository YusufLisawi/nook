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

/// Click, then press a shortcut. Hold modifiers and let go to record a modifier-only shortcut. ⌫ turns it off, Esc cancels.
struct DictationShortcutField: View {
    let storageKey: String
    let fallback: DictationShortcut
    @State private var current: DictationShortcut?
    @State private var recording = false
    @State private var peak: CGEventFlags = []
    @State private var monitor: Any?

    init(storageKey: String, fallback: DictationShortcut) {
        self.storageKey = storageKey
        self.fallback = fallback
        _current = State(initialValue: DictationShortcut.load(storageKey, fallback: fallback))
    }

    var body: some View {
        HStack(spacing: 6) {
            Button(recording ? (peak.isEmpty ? "Press keys…" : Modifiers.symbols(peak) + "…") : (current?.display ?? "Off")) {
                recording ? stop() : start()
            }
            .font(.system(size: 12, design: .rounded))
            .foregroundStyle(current == nil && !recording ? .secondary : .primary)
            if current != fallback {
                Button("Reset") { save(fallback) }.buttonStyle(.link).font(.caption)
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        peak = []
        Services.shared.dictation.hotkeys.paused = true // don't start dictating while recording a shortcut
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            if event.type == .flagsChanged {
                let flags = Modifiers.from(event.modifierFlags)
                if !flags.isEmpty { peak = peak.union(flags) }
                else if !peak.isEmpty { save(DictationShortcut(keyCode: nil, modifiers: peak.rawValue, display: Modifiers.symbols(peak))) }
                return nil
            }
            switch event.keyCode {
            case 53: stop() // Esc
            case 51, 117: save(nil) // Delete → off
            default:
                let flags = Modifiers.from(event.modifierFlags).subtracting(.maskSecondaryFn)
                let isFunctionKey = (96...122).contains(Int(event.keyCode))
                guard !flags.isEmpty || isFunctionKey else { return nil } // plain letters would fire while typing
                save(DictationShortcut(keyCode: Int(event.keyCode), modifiers: flags.rawValue, display: Modifiers.symbols(flags) + Modifiers.keyName(event)))
            }
            return nil
        }
    }

    private func save(_ shortcut: DictationShortcut?) {
        current = shortcut
        DictationShortcut.save(storageKey, shortcut)
        Services.shared.dictation.reloadShortcuts()
        stop()
    }

    private func stop() {
        recording = false
        peak = []
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        Services.shared.dictation.hotkeys.paused = false
    }
}
