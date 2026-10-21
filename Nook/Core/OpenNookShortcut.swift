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

/// Reuses Nook's shortcut encoding; separate from the Settings agent's shortcuts pane.
struct OpenNookShortcutRow: View {
    @State private var shortcut = OpenNookShortcut.current
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        LabeledContent("Open Nook") {
            HStack {
                Button(recording ? "Press shortcut…" : shortcut?.display ?? "Off") { recording ? stop() : start() }
                    .font(.system(size: 12, design: .rounded))
                if shortcut != OpenNookShortcut.defaultShortcut {
                    Button("Reset") { save(OpenNookShortcut.defaultShortcut) }.buttonStyle(.link)
                }
            }
        }
        .help("Press a shortcut with Command, Option or Control. Delete turns it off; Escape cancels.")
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        Services.shared.dictation.hotkeys.paused = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch event.keyCode {
            case 53: stop()
            case 51, 117: save(nil)
            default:
                guard let next = TabHotkeys.make(from: event) else { return nil }
                save(next)
            }
            return nil
        }
    }

    private func save(_ value: TabHotkey?) {
        shortcut = value
        OpenNookShortcut.save(value)
        stop()
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        Services.shared.dictation.hotkeys.paused = false
    }
}
