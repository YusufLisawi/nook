import Combine
import Foundation

/// Only dock presentation lives here. Disabling a plugin remains a separate preference.
final class TabNavigationStore: ObservableObject {
    static let shared = TabNavigationStore()
    @Published private(set) var groups: [TabGroup]
    @Published private(set) var hidden: Set<String>
    @Published private(set) var order: [String]
    @Published private(set) var loadError: String?
    @Published var settingsSelection: String?
    private let defaults: UserDefaults
    private var observer: AnyCancellable?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        groups = []
        hidden = []
        order = []
        reload()
        observer = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.reload() }
    }

    private func reload() {
        let hidden = Set((defaults.stringArray(forKey: Prefs.hiddenTabs) ?? []))
        if self.hidden != hidden { self.hidden = hidden }
        var seen = Set<String>()
        let order = (defaults.stringArray(forKey: Prefs.dockOrder) ?? []).filter { seen.insert($0).inserted }
        if self.order != order { self.order = order }
        do {
            let groups = try defaults.data(forKey: Prefs.tabGroups).map { try JSONDecoder().decode([TabGroup].self, from: $0) } ?? []
            if self.groups != groups { self.groups = groups }
            if loadError != nil { loadError = nil }
        } catch {
            loadError = "Saved tab groups could not be read. Reset groups to start again."
        }
    }

    func group(containing pluginID: String) -> TabGroup? { groups.first { $0.members.contains(pluginID) } }
    func group(_ id: String) -> TabGroup? { groups.first { $0.id == id } }

    func items(pluginIDs: [String], disabled: Set<String> = [], forSettings: Bool = false) -> [DockItem] {
        DockLayout.items(pluginIDs: pluginIDs, groups: groups, hidden: forSettings ? [] : hidden,
                         disabled: forSettings ? [] : disabled, order: order)
    }

    func setHidden(_ id: String, _ value: Bool) {
        if value { hidden.insert(id) } else { hidden.remove(id) }
        defaults.set(hidden.sorted(), forKey: Prefs.hiddenTabs)
    }

    enum GroupError: LocalizedError {
        case name, members, unreadable
        var errorDescription: String? {
            switch self {
            case .name: "Enter a group name of 1–40 characters."
            case .members: "Choose at least two different plugins."
            case .unreadable: "Reset the unreadable saved groups before making changes."
            }
        }
    }

    @discardableResult func save(_ value: TabGroup, pluginIDs: [String]) throws -> TabGroup {
        guard loadError == nil else { throw GroupError.unreadable }
        var group = value
        if let existing = self.group(group.id) { group.lastMember = existing.lastMember }
        group.name = group.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !group.name.isEmpty, group.name.count <= 40 else { throw GroupError.name }
        // Keep temporarily uninstalled members when editing an existing group.
        let available = Set(pluginIDs).union(self.group(group.id)?.members ?? [])
        var seen = Set<String>()
        group.members = group.members.filter { available.contains($0) && seen.insert($0).inserted }
        guard group.members.count >= 2 else { throw GroupError.members }
        if group.symbol.isEmpty { group.symbol = "square.stack" }
        // One plugin belongs to one deck. Dissolving a one-member source deck returns its member to the dock.
        let selected = Set(group.members)
        groups = groups.compactMap { old in
            guard old.id != group.id else { return old }
            var old = old
            old.members.removeAll { selected.contains($0) }
            return old.members.count >= 2 ? old : nil
        }
        if let index = groups.firstIndex(where: { $0.id == group.id }) { groups[index] = group }
        else {
            groups.append(group)
            // Replace the first selected dock item in place, preserving existing user ordering.
            if let index = order.firstIndex(where: { selected.contains($0) }) { order.insert(group.id, at: index) }
        }
        persist()
        return group
    }

    func add(_ pluginID: String, to groupID: String, pluginIDs: [String]) {
        guard var group = group(groupID), !group.members.contains(pluginID) else { return }
        group.members.append(pluginID)
        _ = try? save(group, pluginIDs: pluginIDs)
    }

    func delete(_ id: String) {
        guard let group = group(id) else { return }
        if let index = order.firstIndex(of: id) {
            order.replaceSubrange(index...index, with: group.members.filter { !order.contains($0) })
        }
        groups.removeAll { $0.id == id }
        persist()
    }

    func removeMember(_ pluginID: String, from id: String) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        if groups[index].members.count <= 2 { delete(id); return }
        groups[index].members.removeAll { $0 == pluginID }
        persist()
    }

    func remember(_ pluginID: String) {
        guard let index = groups.firstIndex(where: { $0.members.contains(pluginID) }), groups[index].lastMember != pluginID else { return }
        groups[index].lastMember = pluginID
        persist(notifyShortcuts: false)
    }

    func setHotkey(_ id: String, _ value: TabHotkey?) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].hotkey = value
        persist()
    }

    func moveMembers(_ id: String, from source: IndexSet, to destination: Int) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].members = DockLayout.moved(groups[index].members, from: source, to: destination)
        persist(notifyShortcuts: false)
    }

    func move(items: [DockItem], from source: IndexSet, to destination: Int) {
        // Retain hidden/missing order slots so showing a tab again restores its place.
        let visible = Set(items.map(\.id))
        var moved = DockLayout.moved(items.map(\.id), from: source, to: destination).makeIterator()
        var next = order.map { visible.contains($0) ? (moved.next() ?? $0) : $0 }
        next.append(contentsOf: moved)
        order = next
        defaults.set(order, forKey: Prefs.dockOrder)
    }

    func move(_ id: String, to target: String, items: [DockItem]) {
        guard let from = items.firstIndex(where: { $0.id == id }), let to = items.firstIndex(where: { $0.id == target }), from != to else { return }
        move(items: items, from: IndexSet(integer: from), to: to > from ? to + 1 : to)
    }

    func resetOrder() { order = []; defaults.removeObject(forKey: Prefs.dockOrder) }
    func resetGroups() { groups = []; loadError = nil; persist() }

    private func persist(notifyShortcuts: Bool = true) {
        guard loadError == nil, let data = try? JSONEncoder().encode(groups) else { return }
        defaults.set(data, forKey: Prefs.tabGroups)
        defaults.set(order, forKey: Prefs.dockOrder)
        if notifyShortcuts { NotificationCenter.default.post(name: .nookShortcutsChanged, object: nil) }
    }
}
