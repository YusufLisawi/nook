import Foundation

@main
struct NavigationTests {
    static func main() throws {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message)
            checks += 1
        }
        let ids = ["home", "notes", "files", "clips", "agents"]
        let work = TabGroup(id: "group:work", name: "Work", symbol: "briefcase", members: ["notes", "files"], lastMember: "files")
        let layout = DockLayout.items(pluginIDs: ids, groups: [work])
        check(layout.map(\.id) == ["home", work.id, "clips", "agents"], "A group occupies its earliest member's dock position")
        check(layout[1].pluginIDs == ["notes", "files"], "Member order is independent of dock order")
        check(layout[1].plugin(lastMember: work.lastMember) == "files", "Reopen last member")
        check(layout[1].plugin(lastMember: "missing") == "notes", "Missing last member falls back")
        let hidden = DockLayout.items(pluginIDs: ids, groups: [work], hidden: ["home", "files"])
        check(hidden.map(\.id) == [work.id, "clips", "agents"], "Hidden standalone tabs are absent; visible members retain the group")
        check(hidden[0].pluginIDs == ["notes"], "Hidden members cannot be reached by numbered shortcuts or swipes")
        check(hidden[0].plugin(lastMember: "files") == "notes", "A hidden last member does not leak into numbered navigation")
        check(DockLayout.items(pluginIDs: ids, groups: [work], hidden: ["notes", "files"]).map(\.id) == ["home", "clips", "agents"], "All-hidden groups have no dock item")
        check(DockLayout.items(pluginIDs: ids, groups: [work], disabled: ["notes"]).first { $0.id == work.id }?.pluginIDs == ["files"], "Disabled members skipped without dissolving saved groups")
        check(DockLayout.items(pluginIDs: [], groups: [work]).isEmpty, "Empty registry")
        check(DockLayout.items(pluginIDs: ids, groups: [work], hidden: Set(ids)).isEmpty, "All tabs may be hidden")
        let ordered = DockLayout.items(pluginIDs: ids, groups: [work], order: ["agents", work.id, "gone", work.id, "home"])
        check(ordered.map(\.id) == ["agents", work.id, "home", "clips"], "Custom order is deduplicated; newly installed tabs append")
        check(DockLayout.numbered(2, in: ordered)?.id == work.id, "Command-2 counts a group once")
        check(DockLayout.numbered(0, in: ordered) == nil && DockLayout.numbered(5, in: ordered) == nil, "Invalid number returns no item")
        let many = DockLayout.items(pluginIDs: (1...12).map(String.init), groups: [])
        check(DockLayout.numbered(9, in: many)?.id == "9" && DockLayout.numbered(10, in: many) == nil, "Only Command-1 through 9")
        check(DockLayout.step(from: "agents", by: 1, ids: layout.map(\.id)) == "home", "Forward wraps")
        check(DockLayout.step(from: "home", by: -1, ids: layout.map(\.id)) == "agents", "Backward wraps")
        check(DockLayout.step(from: work.id, by: 1001, ids: layout.map(\.id)) == "clips", "Large step wraps safely")
        check(DockLayout.step(from: "hidden", by: 1, ids: layout.map(\.id)) == "home", "Forward from hidden starts at first")
        check(DockLayout.step(from: "hidden", by: -1, ids: layout.map(\.id)) == "agents", "Backward from hidden starts at last")
        check(DockLayout.step(from: "files", by: 1, ids: work.members) == "notes", "Deck forward wraps independently")
        check(DockLayout.step(from: "notes", by: -1, ids: work.members) == "files", "Deck backward wraps")
        check(DockLayout.step(from: "notes", by: 1, ids: []) == nil, "Empty step")
        check(DockLayout.step(from: "notes", by: -100, ids: ["notes"]) == "notes", "Single visible member")
        check(DockLayout.moved(ids, from: IndexSet([0, 2]), to: 5) == ["notes", "clips", "agents", "home", "files"], "Multi-row drag")
        let invalid = TabGroup(id: "group:invalid", name: "Invalid", symbol: "folder", members: ["notes", "notes"])
        check(DockLayout.items(pluginIDs: ids, groups: [invalid]).map(\.id) == ids, "Malformed singleton is not a deck")
        let overlap = TabGroup(id: "group:other", name: "Other", symbol: "folder", members: ["notes", "clips", "clips"])
        let overlaps = DockLayout.items(pluginIDs: ids + ["home"], groups: [work, overlap])
        check(overlaps.flatMap(\.pluginIDs).sorted() == ids.sorted(), "Overlaps and duplicate plugin IDs never duplicate a destination")
        let roundTrip = try JSONDecoder().decode([TabGroup].self, from: JSONEncoder().encode([work]))
        check(roundTrip == [work], "JSON round trip")

        // Real persistence uses a disposable preference suite, never the running Nook domain.
        let domain = "nook.tabs.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = TabNavigationStore(defaults: defaults)
        store.setHidden("clips", true)
        check(defaults.stringArray(forKey: Prefs.hiddenTabs) == ["clips"], "Hidden preference persists separately")
        check(defaults.object(forKey: Prefs.disabledTabs) == nil, "Hiding never changes enabled preference")
        try store.save(work, pluginIDs: ids)
        store.remember("notes")
        let restored = TabNavigationStore(defaults: defaults)
        check(restored.groups.first?.lastMember == "notes" && restored.hidden == ["clips"], "Groups, visibility, last member survive restart")
        check(restored.items(pluginIDs: ids).map(\.id) == ["home", work.id, "agents"], "Restored dock computation")
        check(restored.items(pluginIDs: ids, disabled: Set(ids), forSettings: true).map(\.id) == layout.map(\.id), "Settings retains hidden and disabled entries")
        let settingsItems = store.items(pluginIDs: ids, forSettings: true)
        store.move(items: settingsItems, from: IndexSet(integer: 1), to: settingsItems.count)
        check(store.items(pluginIDs: ids, forSettings: true).map(\.id) == ["home", "clips", "agents", work.id], "Group dock order persists")
        store.moveMembers(work.id, from: IndexSet(integer: 0), to: 2)
        check(store.group(work.id)?.members == ["files", "notes"], "Deck order persists separately")
        let shortcut = TabHotkey(keyCode: 3, modifiers: 1, display: "Test")
        store.setHotkey(work.id, shortcut)
        check(TabNavigationStore(defaults: defaults).group(work.id)?.hotkey == shortcut, "Group hotkey persists in JSON")
        store.delete(work.id)
        check(store.groups.isEmpty, "Delete removes group")
        check(store.items(pluginIDs: ids, forSettings: true).map(\.id) == ["home", "clips", "agents", "files", "notes"], "Delete expands members at group position")
        check(store.hidden.contains("clips"), "Delete preserves hide preferences")
        do { try store.save(TabGroup(name: " ", symbol: "folder", members: ["home", "notes"]), pluginIDs: ids); preconditionFailure("Empty name") } catch { checks += 1 }
        do { try store.save(TabGroup(name: "Work", symbol: "folder", members: ["notes", "notes", "unknown"]), pluginIDs: ids); preconditionFailure("Too few available members") } catch { checks += 1 }
        try store.save(work, pluginIDs: ids)
        let other = TabGroup(id: "group:new", name: "New", symbol: "folder", members: ["files", "agents"])
        try store.save(other, pluginIDs: ids)
        check(store.groups.map(\.id) == [other.id], "Moving a member out of a pair dissolves its former group")
        check(store.items(pluginIDs: ids, forSettings: true).flatMap(\.pluginIDs).sorted() == ids.sorted(), "Membership moves never lose or duplicate plugins")
        var renamed = store.group(other.id)!
        renamed.name = "Renamed"
        try store.save(renamed, pluginIDs: ids.filter { $0 != "files" })
        check(store.group(other.id)?.members == ["files", "agents"], "Editing preserves a temporarily missing configured member")
        check(store.items(pluginIDs: ids.filter { $0 != "files" }, forSettings: true).first { $0.id == other.id }?.pluginIDs == ["agents"], "Temporarily missing plugin is skipped at runtime")
        store.removeMember("agents", from: other.id)
        check(store.groups.isEmpty, "Removing a member from a pair returns both to the dock")
        defaults.set(Data("{broken".utf8), forKey: Prefs.tabGroups)
        let broken = TabNavigationStore(defaults: defaults)
        check(broken.loadError != nil, "Corrupt JSON is visible")
        do { try broken.save(work, pluginIDs: ids); preconditionFailure("Overwrote unreadable groups") } catch { checks += 1 }
        check(defaults.data(forKey: Prefs.tabGroups) == Data("{broken".utf8), "Corrupt data remains intact until explicit reset")
        broken.resetGroups()
        check(broken.loadError == nil && broken.groups.isEmpty, "Explicit reset recovers")
        print("Passed \(checks) tab navigation, deck, ordering, visibility and isolated persistence checks")
    }
}
