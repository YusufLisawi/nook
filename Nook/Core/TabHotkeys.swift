import AppKit
import SwiftUI

/// Global shortcut per tab, e.g. ⌘⌥N → open Notes. Stored as JSON in UserDefaults.
struct TabHotkey: Codable, Equatable {
    var keyCode: Int
    var modifiers: UInt64 // CGEventFlags raw value (⌃⌥⌘⇧ only)
    var display: String
}

enum TabHotkeys {
    private static let key = "tabHotkeys"
    static let relevant: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand, .maskShift]

    static func all() -> [String: TabHotkey] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: TabHotkey].self, from: data)) ?? [:]
    }

    static func get(_ tabID: String) -> TabHotkey? { all()[tabID] }

    static func set(_ tabID: String, _ hotkey: TabHotkey?) {
        var dict = all()
        dict[tabID] = hotkey
        UserDefaults.standard.set(try? JSONEncoder().encode(dict), forKey: key)
    }

    static func tab(forKey keyCode: Int64, modifiers: CGEventFlags) -> String? {
        all().first { $0.value.keyCode == Int(keyCode) && $0.value.modifiers == modifiers.rawValue }?.key
    }

    static func make(from event: NSEvent) -> TabHotkey? {
        var flags: CGEventFlags = []
        var symbols = ""
        let m = event.modifierFlags
        if m.contains(.control) { flags.insert(.maskControl); symbols += "⌃" }
        if m.contains(.option) { flags.insert(.maskAlternate); symbols += "⌥" }
        if m.contains(.shift) { flags.insert(.maskShift); symbols += "⇧" }
        if m.contains(.command) { flags.insert(.maskCommand); symbols += "⌘" }
        // Need ⌃, ⌥ or ⌘ so plain typing never triggers a tab.
        guard !flags.intersection([.maskControl, .maskAlternate, .maskCommand]).isEmpty else { return nil }
        let names: [UInt16: String] = [49: "Space", 36: "↩", 48: "⇥", 123: "←", 124: "→", 125: "↓", 126: "↑",
                                       122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6"]
        let name = names[event.keyCode] ?? (event.charactersIgnoringModifiers ?? "?").uppercased()
        return TabHotkey(keyCode: Int(event.keyCode), modifiers: flags.rawValue, display: symbols + name)
    }
}

/// Click, then press a shortcut. Esc cancels, ⌫ clears.
struct HotkeyRecorder: View {
    let tabID: String
    @State private var hotkey: TabHotkey?
    @State private var recording = false
    @State private var monitor: Any?

    init(tabID: String) {
        self.tabID = tabID
        _hotkey = State(initialValue: TabHotkeys.get(tabID))
    }

    var body: some View {
        Button(recording ? "Press keys…" : (hotkey?.display ?? "Add shortcut")) {
            recording ? stop() : start()
        }
        .font(.system(size: 11, design: .rounded))
        .foregroundStyle(hotkey == nil && !recording ? .secondary : .primary)
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch event.keyCode {
            case 53: break // Esc
            case 51, 117: // Delete
                hotkey = nil
                TabHotkeys.set(tabID, nil)
            default:
                guard let made = TabHotkeys.make(from: event) else { return nil }
                hotkey = made
                TabHotkeys.set(tabID, made)
            }
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
