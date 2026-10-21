import SwiftUI

struct ShortcutsPane: View {
    @ObservedObject private var plugins = Services.shared.plugins
    @ObservedObject private var commands = Services.shared.commands
    @State private var revision = 0
    @State private var trusted = AXIsProcessTrusted()

    var body: some View {
        let _ = revision
        let items = SettingsShortcutItem.all
        Form {
            if !trusted {
                Section {
                    Label("Allow Accessibility to use global shortcuts.", systemImage: "hand.raised")
                        .foregroundStyle(.secondary)
                    Button("Open Accessibility Settings…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                }
            }
            Section {
                Text("Click a recorder, then press a shortcut. Esc cancels; Delete clears it. Existing assignments are checked across all tabs, AI commands, dictation, and registered extensions.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            shortcutSection("Tabs & Plugins", items: plugins.orderedTabs.map(SettingsShortcutItem.tab))
            shortcutSection("AI Commands", items: commands.commands.map(SettingsShortcutItem.command))
            Section {
                ForEach([SettingsShortcutItem.dictation(hold: true), .dictation(hold: false)]) { item in
                    LabeledContent(item.title) { SettingsShortcutRecorder(item: item) }
                }
                Button("Restore Dictation Defaults") {
                    DictationShortcut.save(DictationService.Keys.holdShortcut, .defaultHold)
                    DictationShortcut.save(DictationService.Keys.toggleShortcut, .defaultToggle)
                    Services.shared.dictation.reloadShortcuts()
                    NotificationCenter.default.post(name: .nookShortcutsChanged, object: nil)
                }
            } header: {
                Text("Dictation")
            } footer: {
                Text("Hold to Talk records while held. Toggle Recording starts on the first press and transcribes on the next. Modifier-only gestures are supported.")
            }
            let groups = Set(ShortcutRegistry.shortcuts.map(\.group)).sorted()
            ForEach(groups, id: \.self) { group in
                shortcutSection(group, items: items.filter { $0.id.hasPrefix("extension:") && $0.group == group })
            }
            if ShortcutRegistry.shortcuts.isEmpty {
                Section("Extensions") {
                    Text("No extension shortcuts registered.").foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: .nookShortcutsChanged)) { _ in revision += 1 }
        .onAppear { trusted = AXIsProcessTrusted() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            trusted = AXIsProcessTrusted()
        }
    }

    private func shortcutSection(_ title: String, items: [SettingsShortcutItem]) -> some View {
        Section(title) {
            if items.isEmpty {
                Text(title == "AI Commands" ? "Create an AI command to assign it a shortcut." : "No shortcuts in this group.")
                    .foregroundStyle(.secondary)
            }
            ForEach(items) { item in
                LabeledContent(item.title) { SettingsShortcutRecorder(item: item) }
            }
        }
    }
}
