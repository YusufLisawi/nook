import SwiftUI

struct ShortcutsPane: View {
    @ObservedObject private var plugins = Services.shared.plugins
    @ObservedObject private var features = Features.shared
    @ObservedObject private var navigation = TabNavigationStore.shared
    @State private var revision = 0
    @State private var trusted = AXIsProcessTrusted()
    @State private var restoreError: String?

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
            shortcutSection("Tabs & Plugins", items: plugins.orderedTabs.filter { features.tabEnabled($0.id) }.map(SettingsShortcutItem.tab))
            if !navigation.groups.isEmpty {
                shortcutSection("Tab Groups", items: navigation.groups.filter { $0.members.contains(where: features.tabEnabled) }.map(SettingsShortcutItem.group))
            }
            if !PluginGestureHotkeys.shared.items.isEmpty { shortcutSection("Plugin gestures",items:PluginGestureHotkeys.shared.items) }
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
