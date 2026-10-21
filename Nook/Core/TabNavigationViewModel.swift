import AppKit
import SwiftUI

extension NotchViewModel {
    var dockItems: [DockItem] {
        Array(TabNavigationStore.shared.items(pluginIDs: enabledTabs.map(\.id), disabled: Prefs.disabledTabSet)
            .prefix(DockLayout.limit))
    }

    var currentGroup: TabGroup? { TabNavigationStore.shared.group(containing: tab) }
    var currentDockID: String { currentGroup?.id ?? tab }

    func navigationIndices(to id: String) -> (Int, Int)? {
        if let group = currentGroup, let from = group.members.firstIndex(of: tab), let to = group.members.firstIndex(of: id) {
            return (from, to)
        }
        let target = TabNavigationStore.shared.group(containing: id)?.id ?? id
        let dock = dockItems.map(\.id)
        if let from = dock.firstIndex(of: currentDockID), let to = dock.firstIndex(of: target) { return (from, to) }
        let plugins = enabledTabs.map(\.id)
        if let from = plugins.firstIndex(of: tab), let to = plugins.firstIndex(of: id) { return (from, to) }
        return nil
    }

    /// Hidden members remain directly addressable but never become a swipe/number-key destination.
    var deckTabs: [TabItem] {
        guard let group = currentGroup else { return [] }
        let hidden = TabNavigationStore.shared.hidden
        return group.members.compactMap { id in enabledTabs.first { $0.id == id && !hidden.contains(id) } }
    }

    var deckDisplayTabs: [TabItem] {
        guard let group = currentGroup else { return [] }
        return group.members.compactMap { id in enabledTabs.first { $0.id == id && (id == tab || !TabNavigationStore.shared.hidden.contains(id)) } }
    }

    func selectDockItem(_ item: DockItem) {
        let last = item.groupID.flatMap { TabNavigationStore.shared.group($0)?.lastMember }
        if let id = item.plugin(lastMember: last) { select(id) }
    }

    func stepDeck(_ delta: Int) {
        guard currentGroup != nil, let id = DockLayout.step(from: tab, by: delta, ids: deckTabs.map(\.id)) else { return }
        slideEdge = delta > 0 ? .trailing : .leading
        withAnimation(.snappy(duration: 0.28)) { tab = id }
    }

    func swipeTabs(_ delta: Int) {
        if currentGroup != nil { stepDeck(delta) } else { step(delta) }
    }

    func toggleGroup(_ id: String) {
        if isOpen && currentGroup?.id == id { close(); return }
        guard let group = TabNavigationStore.shared.group(id) else { return }
        let members = group.members.filter(isEnabled)
        if let member = members.contains(group.lastMember ?? "") ? group.lastMember : members.first { open(tab: member) }
    }

    /// Runs after a preference/plugin update, never rewrites active IDs for mere visibility changes.
    func reconcileTabNavigation() {
        if !isEnabled(tab), let first = enabledTabs.first { select(first.id) }
        objectWillChange.send()
    }
}
