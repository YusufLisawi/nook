import SwiftUI

struct TabNavigationList: View {
    @Binding var selection: String?
    @ObservedObject private var plugins = Services.shared.plugins
    @ObservedObject private var navigation = TabNavigationStore.shared
    @AppStorage(Prefs.disabledTabs) private var disabledTabs = ""
    @State private var expanded: Set<String> = []
    @State private var creating = false
    @State private var reloading = false

    private var items: [DockItem] { navigation.items(pluginIDs: plugins.orderedTabs.map(\.id), forSettings: true) }

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(items) { item in
                    if let id = item.groupID, let group = navigation.group(id) {
                        DisclosureGroup(isExpanded: Binding(get: { expanded.contains(id) }, set: { on in
                            if on { expanded.insert(id) } else { expanded.remove(id) }
                        })) {
                            ForEach(group.members, id: \.self) { member in
                                if let tab = plugins.tabs.first(where: { $0.id == member }) {
                                    pluginRow(tab).tag(member)
                                        .contextMenu { memberMenu(group, member: member) }
                                } else {
                                    Label(member + " (Unavailable)", systemImage: "puzzlepiece.extension")
                                        .foregroundStyle(.secondary)
                                        .contextMenu { memberMenu(group, member: member) }
                                }
                            }
                            .onMove { navigation.moveMembers(id, from: $0, to: $1) }
                        } label: {
                            HStack(spacing: 9) {
                                Image(systemName: group.symbol).frame(width: 18).foregroundStyle(.secondary)
                                Text(group.name).lineLimit(1)
                                Spacer(minLength: 0)
                                Text("\(group.members.count)").font(.caption).foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 5)
                        }
                        .tag(id)
                        .contextMenu {
                            orderMenu(id)
                            Divider()
                            Button("Delete Group", role: .destructive) { navigation.delete(id) }
                        }
                    } else if let tab = plugins.tabs.first(where: { $0.id == item.id }) {
                        pluginRow(tab).tag(tab.id)
                            .contextMenu { orderMenu(tab.id) }
                    }
                }
                .onMove { navigation.move(items: items, from: $0, to: $1) }
                let missingGroups = navigation.groups.filter { group in !items.contains { $0.id == group.id } }
                if !missingGroups.isEmpty {
                    Section("Unavailable Groups") {
                        ForEach(missingGroups) { group in
                            Label(group.name, systemImage: group.symbol).tag(group.id)
                                .contextMenu { Button("Delete Group", role: .destructive) { navigation.delete(group.id) } }
                        }
                    }
                }
            }
            .listStyle(.inset)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                if let error = navigation.loadError {
                    Text(error).font(.caption).foregroundStyle(.red)
                    Button("Reset Groups") { navigation.resetGroups() }
                }
                Button("New Group…", systemImage: "plus") { creating = true }.disabled(navigation.loadError != nil)
                Text("Drag dock items or expand a group to arrange its deck. Hidden plugins stay enabled.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Plugins Folder", systemImage: "folder") { NSWorkspace.shared.open(PluginRegistry.userDir) }
                    if reloading { ProgressView().controlSize(.small).accessibilityLabel("Reloading plugins") }
                    Spacer(minLength: 2)
                    Menu {
                        Button("Reload Plugins") {
                            reloading = true
                            Task { await plugins.reloadForSettings(); reloading = false }
                        }.disabled(reloading)
                        Button("Reset Dock Order") { navigation.resetOrder(); plugins.resetOrder() }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Plugin actions")
                }
            }
            .controlSize(.small).padding(12)
        }
        .sheet(isPresented: $creating) {
            TabGroupEditor(draft: TabGroup(name: "", symbol: "square.stack", members: plugins.tabs.filter { $0.id == selection }.map(\.id))) { id in
                selection = id
                expanded.insert(id)
            }
        }
    }

    private func pluginRow(_ tab: TabItem) -> some View {
        HStack(spacing: 9) {
            SettingsTabIcon(tab: tab, revision: plugins.revision)
            Text(tab.name).lineLimit(1).help(tab.name).foregroundStyle(enabled(tab.id).wrappedValue ? .primary : .secondary)
            Spacer(minLength: 2)
            if navigation.hidden.contains(tab.id) {
                Image(systemName: "eye.slash").font(.caption).foregroundStyle(.tertiary).help("Hidden from dock")
            }
            Toggle("Enable \(tab.name)", isOn: enabled(tab.id)).labelsHidden().toggleStyle(.switch).controlSize(.mini)
        }
        .padding(.vertical, 5)
    }

    @ViewBuilder private func orderMenu(_ id: String) -> some View {
        Button("Move Up") { move(id, by: -1) }.disabled(items.first?.id == id)
        Button("Move Down") { move(id, by: 1) }.disabled(items.last?.id == id)
    }

    @ViewBuilder private func memberMenu(_ group: TabGroup, member: String) -> some View {
        Button("Move Up") { moveMember(group, member: member, by: -1) }.disabled(group.members.first == member)
        Button("Move Down") { moveMember(group, member: member, by: 1) }.disabled(group.members.last == member)
        Button("Remove from Group") { navigation.removeMember(member, from: group.id) }
    }

    private func move(_ id: String, by offset: Int) {
        guard let index = items.firstIndex(where: { $0.id == id }), items.indices.contains(index + offset) else { return }
        navigation.move(id, to: items[index + offset].id, items: items)
    }
    private func moveMember(_ group: TabGroup, member: String, by offset: Int) {
        guard let index = group.members.firstIndex(of: member), group.members.indices.contains(index + offset) else { return }
        navigation.moveMembers(group.id, from: IndexSet(integer: index), to: offset > 0 ? index + 2 : index - 1)
    }
    private func enabled(_ id: String) -> Binding<Bool> {
        Binding(get: { !disabledTabs.split(separator: ",").contains(Substring(id)) }, set: { on in
            var off = Prefs.disabledTabSet
            if on { off.remove(id) } else { off.insert(id) }
            disabledTabs = off.sorted().joined(separator: ",")
        })
    }
}
