import Foundation

/// A deck is presentation only: plugin IDs remain the identity used by every service and bridge.
struct TabGroup: Codable, Equatable, Identifiable {
    var id = "group:" + UUID().uuidString.lowercased()
    var name: String
    var symbol: String
    var members: [String]
    var hotkey: TabHotkey?
    var lastMember: String?
}

struct DockItem: Equatable, Identifiable {
    let id: String
    let groupID: String?
    let pluginIDs: [String]

    func plugin(lastMember: String?) -> String? {
        if let lastMember, pluginIDs.contains(lastMember) { return lastMember }
        return pluginIDs.first
    }
}

/// Pure navigation policy, independent of preferences, AppKit, and running plugins.
enum DockLayout {
    /// The dock shows at most this many items; make groups (or hide tabs) for more. The rest stay reachable by hotkey, ⌘K and the launcher.
    static let limit = 12

    static func items(pluginIDs: [String], groups: [TabGroup], hidden: Set<String> = [],
                      disabled: Set<String> = [], order: [String] = []) -> [DockItem] {
        let available = Set(pluginIDs).subtracting(disabled).subtracting(hidden)
        var membership: [String: TabGroup] = [:]
        for group in groups where Set(group.members).count >= 2 {
            for member in group.members where membership[member] == nil { membership[member] = group }
        }
        var seen = Set<String>()
        var result: [DockItem] = []
        for pluginID in pluginIDs where available.contains(pluginID) {
            let group = membership[pluginID]
            let id = group?.id ?? pluginID
            guard seen.insert(id).inserted else { continue }
            var membersSeen = Set<String>()
            let members = (group?.members ?? [pluginID]).filter {
                available.contains($0) && (group == nil || membership[$0]?.id == id) && membersSeen.insert($0).inserted
            }
            if !members.isEmpty { result.append(DockItem(id: id, groupID: group?.id, pluginIDs: members)) }
        }
        var ordered = Set<String>()
        let byID = Dictionary(uniqueKeysWithValues: result.map { ($0.id, $0) })
        return order.compactMap { id in ordered.insert(id).inserted ? byID[id] : nil }
            + result.filter { !ordered.contains($0.id) }
    }

    static func numbered(_ number: Int, in items: [DockItem]) -> DockItem? {
        guard (1...9).contains(number), items.indices.contains(number - 1) else { return nil }
        return items[number - 1]
    }

    /// An explicitly opened hidden tab has no dock position: forward starts at the first, back at the last.
    static func step(from id: String, by delta: Int, ids: [String]) -> String? {
        guard !ids.isEmpty else { return nil }
        guard let index = ids.firstIndex(of: id) else { return delta < 0 ? ids.last : ids.first }
        let offset = delta % ids.count
        return ids[(index + offset + ids.count) % ids.count]
    }

    static func moved(_ ids: [String], from source: IndexSet, to destination: Int) -> [String] {
        let source = source.filter { ids.indices.contains($0) }
        let values = source.map { ids[$0] }
        var result = ids.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        let insertion = min(result.count, max(0, destination - source.filter { $0 < destination }.count))
        result.insert(contentsOf: values, at: insertion)
        return result
    }
}
