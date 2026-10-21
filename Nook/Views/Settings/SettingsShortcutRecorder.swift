import SwiftUI

/// Storage adapters keep the central pane and inline controls editing exactly the same preferences.
struct SettingsShortcutItem: Identifiable {
    let id: String
    let title: String
    let group: String
    var allowsModifierOnly = false
    var defaultShortcut: DictationShortcut? = nil
    var editable = true
    let get: () -> DictationShortcut?
    let set: (DictationShortcut?) -> Void

    static func tab(_ tab: TabItem) -> Self {
        Self(id: "tab:\(tab.id)", title: tab.name, group: "Tabs & Plugins",
             get: { TabHotkeys.get(tab.id).map(convert) },
             set: { TabHotkeys.set(tab.id, $0.flatMap(convert)) })
    }

    static func command(_ command: AICommands.Command) -> Self {
        Self(id: "command:\(command.id)", title: command.name, group: "AI Commands",
             get: { Services.shared.commands.commands.first { $0.id == command.id }?.hotkey.map(convert) },
             set: { Services.shared.commands.setHotkey(command.id, $0.flatMap(convert)) })
    }

    static func dictation(hold: Bool) -> Self {
        let key = hold ? DictationService.Keys.holdShortcut : DictationService.Keys.toggleShortcut
        let fallback: DictationShortcut = hold ? .defaultHold : .defaultToggle
        return Self(id: hold ? "dictation:hold" : "dictation:toggle", title: hold ? "Hold to Talk" : "Toggle Recording",
                    group: "Dictation", allowsModifierOnly: true, defaultShortcut: fallback,
                    get: { DictationShortcut.load(key, fallback: fallback) },
                    set: { DictationShortcut.save(key, $0); Services.shared.dictation.reloadShortcuts() })
    }

    static func group(_ group: TabGroup) -> Self {
        Self(id: "group:\(group.id)", title: group.name, group: "Tab Groups",
             get: { TabNavigationStore.shared.group(group.id)?.hotkey.map(convert) },
             set: { TabNavigationStore.shared.setHotkey(group.id, $0.flatMap(convert)) })
    }

    static func registration(_ registration: ShortcutRegistration) -> Self {
        Self(id: "extension:\(registration.id)", title: registration.title, group: registration.group,
             defaultShortcut: registration.defaultShortcut.map(convert),
             editable: registration.editable,
             get: { registration.get().map(convert) }, set: { registration.set($0.flatMap(convert)) })
    }

    static var all: [Self] {
        Services.shared.plugins.orderedTabs.filter { Features.shared.tabEnabled($0.id) }.map(Self.tab)
        + (Features.shared.enabled("commands") ? Services.shared.commands.commands.map(Self.command) : [])
        + (Features.shared.enabled("dictation") ? [Self.dictation(hold: true), Self.dictation(hold: false)] : [])
        + TabNavigationStore.shared.groups.filter { $0.members.contains(where: Features.shared.tabEnabled) }.map(Self.group)
        + ShortcutRegistry.shortcuts.map(Self.registration)
    }

    func conflicts(with shortcut: DictationShortcut, excluding ids: Set<String> = []) -> [Self] {
        Self.all.filter { other in
            other.id != id && !ids.contains(other.id) && other.get().map { ShortcutIdentity($0) == ShortcutIdentity(shortcut) } == true
        }
    }

    func rejection(for shortcut: DictationShortcut, excluding ids: Set<String> = []) -> String? {
        if let conflict = conflicts(with: shortcut, excluding: ids).first {
            return "Already used by \(conflict.title) (\(conflict.group)). Choose another shortcut."
        }
        if let key = Self.convert(shortcut), let conflict = ShortcutRegistry.externalConflicts(key).first {
            return "Already used by \(conflict). Choose another shortcut."
        }
        return nil
    }

    private static func convert(_ key: TabHotkey) -> DictationShortcut {
        DictationShortcut(keyCode: key.keyCode, modifiers: key.modifiers, display: key.display)
    }

    private static func convert(_ key: DictationShortcut) -> TabHotkey? {
        guard let code = key.keyCode else { return nil }
        return TabHotkey(keyCode: code, modifiers: key.modifiers, display: key.display)
    }
}

/// A single monitor prevents two recorders from swallowing the same event or leaving hotkeys paused.
private final class SettingsShortcutSession: ObservableObject {
    static let shared = SettingsShortcutSession()
    @Published private(set) var id: String?
    @Published private(set) var peak: CGEventFlags = []
    private var monitor: Any?

    func start(_ item: SettingsShortcutItem, report: @escaping (String?) -> Void) {
        stop()
        report(nil)
        id = item.id
        Services.shared.hotkeys.paused = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            if event.type == .flagsChanged {
                guard item.allowsModifierOnly else { return event }
                let flags = Modifiers.from(event.modifierFlags)
                if !flags.isEmpty { self.peak.formUnion(flags) }
                else if !self.peak.isEmpty {
                    self.save(DictationShortcut(keyCode: nil, modifiers: self.peak.rawValue, display: Modifiers.symbols(self.peak)), for: item, report: report)
                }
                return nil
            }
            switch event.keyCode {
            case 53: self.stop()
            case 51, 117: self.save(nil, for: item, report: report)
            default:
                let flags = Modifiers.from(event.modifierFlags).subtracting(.maskSecondaryFn)
                let functionKeys: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
                let valid = item.allowsModifierOnly
                    ? (!flags.isEmpty || functionKeys.contains(event.keyCode))
                    : !flags.intersection([.maskControl, .maskAlternate, .maskCommand]).isEmpty
                guard valid else {
                    report(item.allowsModifierOnly ? "Use modifiers or a function key." : "Include ⌘, ⌥, or ⌃ in the shortcut.")
                    return nil
                }
                self.save(DictationShortcut(keyCode: Int(event.keyCode), modifiers: flags.rawValue,
                                           display: Modifiers.symbols(flags) + Modifiers.keyName(event)), for: item, report: report)
            }
            return nil
        }
    }

    private func save(_ shortcut: DictationShortcut?, for item: SettingsShortcutItem, report: (String?) -> Void) {
        if let shortcut, let rejection = item.rejection(for: shortcut) {
            report(rejection)
            stop()
            return
        }
        item.set(shortcut)
        report(nil)
        NotificationCenter.default.post(name: .nookShortcutsChanged, object: nil)
        stop()
    }

    func stop() {
        guard id != nil else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        id = nil
        peak = []
        Services.shared.hotkeys.paused = false
    }
}

struct SettingsShortcutRecorder: View {
    let item: SettingsShortcutItem
    @ObservedObject private var session = SettingsShortcutSession.shared
    @State private var message: String?
    @State private var revision = 0
    private var recording: Bool { session.id == item.id }

    var body: some View {
        let _ = revision
        let current = item.get()
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 8) {
                if !item.editable {
                    Text(current?.display ?? "—").foregroundStyle(.secondary)
                        .font(.system(.body, design: .rounded))
                } else {
                    Button(recording ? (session.peak.isEmpty ? "Press keys…" : Modifiers.symbols(session.peak) + "…") : (current?.display ?? "Record Shortcut")) {
                        if recording { session.stop() } else { session.start(item) { message = $0 } }
                    }
                    .font(.system(.body, design: .rounded))
                    .accessibilityLabel("\(item.title) shortcut")
                    .accessibilityValue(recording ? "Recording" : (current?.display ?? "Not set"))
                    if current != nil, !recording {
                        Button {
                            item.set(nil)
                            message = nil
                            NotificationCenter.default.post(name: .nookShortcutsChanged, object: nil)
                        } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                        .accessibilityLabel("Clear \(item.title) shortcut")
                    }
                }
            }
            if let fallback = item.defaultShortcut, current != fallback, !recording {
                Button("Restore Default") {
                    if let rejection = item.rejection(for: fallback) { message = rejection; return }
                    item.set(fallback)
                    message = nil
                    NotificationCenter.default.post(name: .nookShortcutsChanged, object: nil)
                }
                .buttonStyle(.link).font(.caption)
            }
            if recording {
                Text(item.allowsModifierOnly ? "Release modifiers to record a gesture. Esc cancels; Delete clears." : "Esc cancels; Delete clears.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if item.editable, let current, let rejection = item.rejection(for: current) {
                Label(rejection, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .nookShortcutsChanged)) { _ in revision += 1 }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in revision += 1 }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            if recording { session.stop() }
        }
        .onDisappear { if recording { session.stop() } }
    }
}
