import SwiftUI

/// The same editor creates and edits decks; changes stay in the sheet until Save.
struct TabGroupEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var plugins = Services.shared.plugins
    @ObservedObject private var navigation = TabNavigationStore.shared
    @State var draft: TabGroup
    var onSave: (String) -> Void = { _ in }
    @State private var error: String?

    static let symbols = ["square.stack", "rectangle.3.group", "folder", "square.grid.2x2", "briefcase", "sparkles", "terminal", "hammer", "pencil.and.outline", "music.note", "globe", "tray.full"]
    static let symbolNames = ["square.stack": "Stack", "rectangle.3.group": "Deck", "folder": "Folder", "square.grid.2x2": "Grid",
                              "briefcase": "Work", "sparkles": "AI", "terminal": "Terminal", "hammer": "Tools",
                              "pencil.and.outline": "Writing", "music.note": "Music", "globe": "Web", "tray.full": "Inbox"]

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $draft.name).textFieldStyle(.roundedBorder)
                    Picker("Symbol", selection: $draft.symbol) {
                        ForEach(Self.symbols, id: \.self) { symbol in
                            Label(Self.symbolNames[symbol] ?? symbol, systemImage: symbol).tag(symbol)
                        }
                        if !Self.symbols.contains(draft.symbol) { Label(draft.symbol, systemImage: draft.symbol).tag(draft.symbol) }
                    }
                    LabeledContent("Keyboard shortcut") { SettingsShortcutRecorder(item: shortcutItem) }
                } header: {
                    Label(navigation.group(draft.id) == nil ? "New Group" : "Edit Group", systemImage: draft.symbol)
                } footer: {
                    Text("The shortcut opens the last member you used. Members keep their own shortcuts.")
                }
                Section {
                    ForEach(plugins.orderedTabs) { plugin in
                        Toggle(isOn: Binding(get: { draft.members.contains(plugin.id) }, set: { selected in
                            if selected { draft.members.append(plugin.id) }
                            else { draft.members.removeAll { $0 == plugin.id } }
                        })) {
                            HStack {
                                Label(plugin.name, systemImage: plugin.symbol)
                                Spacer()
                                if let existing = navigation.group(containing: plugin.id), existing.id != draft.id {
                                    Text("In \(existing.name)").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    ForEach(draft.members.filter { id in !plugins.tabs.contains { $0.id == id } }, id: \.self) { id in
                        Toggle("\(id) (Unavailable)", isOn: Binding(get: { draft.members.contains(id) }, set: { selected in
                            if !selected { draft.members.removeAll { $0 == id } }
                        }))
                        .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Members · \(draft.members.count) selected")
                } footer: {
                    Text("Choose at least two plugins. Choosing a member of another group moves it here. Hide and enable preferences are kept.")
                }
                if let error { Section { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) } }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save Group") { save() }.keyboardShortcut(.defaultAction)
                    .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || Set(draft.members).count < 2)
            }
            .padding(16)
        }
        .frame(width: 500, height: 580)
    }

    private var shortcutItem: SettingsShortcutItem {
        SettingsShortcutItem(id: "group:\(draft.id)", title: draft.name.isEmpty ? "New Group" : draft.name, group: "Tab Groups",
                             get: { draft.hotkey.map { DictationShortcut(keyCode: $0.keyCode, modifiers: $0.modifiers, display: $0.display) } },
                             set: { value in draft.hotkey = value.flatMap { key in
                                 key.keyCode.map { TabHotkey(keyCode: $0, modifiers: key.modifiers, display: key.display) }
                             } })
    }

    private func save() {
        if let key = shortcutItem.get(), let rejection = shortcutItem.rejection(for: key) { error = rejection; return }
        do {
            let group = try navigation.save(draft, pluginIDs: plugins.orderedTabs.map(\.id))
            onSave(group.id)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct TabGroupDetail: View {
    let groupID: String
    @ObservedObject private var navigation = TabNavigationStore.shared
    @ObservedObject private var plugins = Services.shared.plugins
    @State private var editing = false

    var body: some View {
        if let group = navigation.group(groupID) {
            Form {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: group.symbol).font(.system(size: 28)).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(group.name).font(.headline)
                            Text("\(group.members.count) plugins · one dock icon").foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Edit Group…") { editing = true }
                    }
                    LabeledContent("Keyboard shortcut") { SettingsShortcutRecorder(item: .group(group)) }
                } footer: {
                    Text("Open a member directly with its shortcut or the command palette. ⌥⌘← / ⌥⌘→ and horizontal swipes move within the deck; ⌃Tab moves between dock items.")
                }
                Section {
                    ForEach(group.members, id: \.self) { id in
                        let tab = plugins.tabs.first { $0.id == id }
                        HStack {
                            Label(tab?.name ?? id, systemImage: tab?.symbol ?? "puzzlepiece.extension")
                            Spacer()
                            if tab == nil { Text("Unavailable").foregroundStyle(.secondary) }
                            else if navigation.hidden.contains(id) { Image(systemName: "eye.slash").foregroundStyle(.secondary).help("Hidden from dock navigation") }
                            Menu {
                                Button("Move Up") { moveMember(group, id: id, by: -1) }.disabled(group.members.first == id)
                                Button("Move Down") { moveMember(group, id: id, by: 1) }.disabled(group.members.last == id)
                                Button("Remove from Group") { navigation.removeMember(id, from: group.id) }
                            } label: { Image(systemName: "ellipsis.circle") }
                            .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Actions for \(tab?.name ?? id)")
                        }
                    }
                    .onMove { navigation.moveMembers(group.id, from: $0, to: $1) }
                } header: { Text("Deck Order") } footer: {
                    Text("Drag members in the sidebar to reorder, or use the row menu. Hidden and disabled members are skipped during navigation.")
                }
                Section {
                    Button("Delete Group", role: .destructive) { navigation.delete(group.id) }
                } footer: {
                    Text("Deleting a group returns its members to the dock with their existing visibility, enable, and shortcut preferences.")
                }
            }
            .formStyle(.grouped)
            .sheet(isPresented: $editing) { TabGroupEditor(draft: group) }
        }
    }

    private func moveMember(_ group: TabGroup, id: String, by offset: Int) {
        guard let from = group.members.firstIndex(of: id), group.members.indices.contains(from + offset) else { return }
        navigation.moveMembers(group.id, from: IndexSet(integer: from), to: offset > 0 ? from + 2 : from - 1)
    }
}
