import SwiftUI

struct TabsPane: View {
    @ObservedObject private var plugins = Services.shared.plugins
    @AppStorage(Prefs.disabledTabs) private var disabledTabs = ""
    @State private var selection: String?
    @ObservedObject private var navigation = TabNavigationStore.shared

    var body: some View {
        HSplitView {
            TabNavigationList(selection: $selection)
                .frame(minWidth: 230, idealWidth: 260, maxWidth: 330)
            if let selection, navigation.group(selection) != nil {
                TabGroupDetail(groupID: selection)
                    .frame(minWidth: 430, maxWidth: .infinity, maxHeight: .infinity)
            } else if let tab = plugins.tabs.first(where: { $0.id == selection }) {
                Form {
                    Section {
                        HStack(spacing: 12) {
                            SettingsTabIcon(tab: tab, size: 28, revision: plugins.revision)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(tab.name).font(.headline).textSelection(.enabled)
                                Text(tab.isWeb ? (plugins.isBundled(tab) ? "Built-in plugin" : "Custom plugin") : "Built-in tab")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 4)
                        Toggle("Enable plugin", isOn: enabled(tab.id))
                        Toggle("Hide from dock", isOn: Binding(get: { navigation.hidden.contains(tab.id) },
                                                              set: { navigation.setHidden(tab.id, $0) }))
                        LabeledContent("Keyboard shortcut") { SettingsShortcutRecorder(item: .tab(tab)) }
                    } footer: {
                        Text("A shortcut opens this tab from any app, even when hidden. Hiding removes it from dock navigation; disabling makes it unavailable.")
                    }
                    PluginSettingsForm(tab: tab, grouped: true)
                        .id("\(tab.id):\(tab.dir?.path ?? "native"):\(plugins.revision)")
                }
                .formStyle(.grouped)
                .frame(minWidth: 430, maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("Select a Tab", systemImage: "square.grid.2x2",
                                       description: Text("Choose a tab to change its height, shortcut, and plugin options."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear(perform: reconcileSelection)
        .onChange(of: plugins.tabs) { _, _ in reconcileSelection() }
        .onChange(of: navigation.groups) { _, _ in reconcileSelection() }
        .onReceive(navigation.$settingsSelection) { id in
            if let id { selection = id }
        }
    }

    private func reconcileSelection() {
        if !plugins.tabs.contains(where: { $0.id == selection }) && !navigation.groups.contains(where: { $0.id == selection }) { selection = plugins.orderedTabs.first?.id }
    }

    private func enabled(_ id: String) -> Binding<Bool> {
        Binding(
            get: { !disabledTabs.split(separator: ",").contains(Substring(id)) },
            set: { on in
                var off = Prefs.disabledTabSet
                if on { off.remove(id) } else { off.insert(id) }
                disabledTabs = off.sorted().joined(separator: ",")
            }
        )
    }
}

struct SettingsTabIcon: View {
    let tab: TabItem
    var size: CGFloat = 18
    var revision = 0
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: tab.symbol).resizable().scaledToFit().foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .task(id: "\(tab.icon?.path ?? ""):\(revision)") {
            image = nil
            guard let url = tab.icon else { return }
            let loaded = await Task.detached(priority: .utility) { NSImage(contentsOf: url) }.value
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}
