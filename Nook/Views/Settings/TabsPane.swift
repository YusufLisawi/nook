import SwiftUI

struct TabsPane: View {
    @ObservedObject private var plugins = Services.shared.plugins
    @AppStorage(Prefs.disabledTabs) private var disabledTabs = ""
    @State private var selection: String?
    @State private var reloading = false

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(plugins.orderedTabs) { tab in
                        HStack(spacing: 9) {
                            SettingsTabIcon(tab: tab, revision: plugins.revision)
                            Text(tab.name).lineLimit(1).help(tab.name)
                                .foregroundStyle(enabled(tab.id).wrappedValue ? .primary : .secondary)
                            Spacer(minLength: 2)
                            Toggle("Enable \(tab.name)", isOn: enabled(tab.id))
                                .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                        }
                        .padding(.vertical, 5)
                        .tag(tab.id)
                        .contextMenu {
                            Button("Move Up") { move(tab.id, by: -1) }
                                .disabled(plugins.orderedTabs.first?.id == tab.id)
                            Button("Move Down") { move(tab.id, by: 1) }
                                .disabled(plugins.orderedTabs.last?.id == tab.id)
                        }
                    }
                    .onMove { plugins.move(from: $0, to: $1) }
                }
                .listStyle(.inset)
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text("Drag to reorder the notch dock. Use the row menu to move a tab with the keyboard.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Plugins Folder", systemImage: "folder") { NSWorkspace.shared.open(PluginRegistry.userDir) }
                            .help("Open Plugins Folder")
                        if reloading { ProgressView().controlSize(.small).accessibilityLabel("Reloading plugins") }
                        Spacer(minLength: 4)
                        Menu {
                            Button("Reload Plugins") {
                                reloading = true
                                Task { await plugins.reloadForSettings(); reloading = false }
                            }
                            .disabled(reloading)
                            Button("Reset Tab Order") { plugins.resetOrder() }.disabled(plugins.customOrder.isEmpty)
                        } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).fixedSize()
                        .accessibilityLabel("Plugin actions")
                    }
                    .controlSize(.small)
                }
                .padding(12)
            }
            .frame(minWidth: 210, idealWidth: 230, maxWidth: 300)
            if let tab = plugins.tabs.first(where: { $0.id == selection }) {
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
                        Toggle("Show in the notch dock", isOn: enabled(tab.id))
                        LabeledContent("Keyboard shortcut") { SettingsShortcutRecorder(item: .tab(tab)) }
                    } footer: {
                        Text("A shortcut opens this tab from any app. Press it again to close the notch.")
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
    }

    private func reconcileSelection() {
        if !plugins.tabs.contains(where: { $0.id == selection }) { selection = plugins.orderedTabs.first?.id }
    }

    private func move(_ id: String, by offset: Int) {
        let tabs = plugins.orderedTabs
        guard let index = tabs.firstIndex(where: { $0.id == id }), tabs.indices.contains(index + offset) else { return }
        plugins.move(id, to: tabs[index + offset].id)
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

private struct SettingsTabIcon: View {
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
