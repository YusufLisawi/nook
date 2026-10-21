import AppKit

/// Registrations belong to a web host, so actions never leak to another display.
final class KeyboardActions: ObservableObject {
    struct Action: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let shortcut: String
        let pluginID: String
        let ownerID: String
    }

    static let shared = KeyboardActions()
    @Published private(set) var actions: [Action] = []

    static let extensionOwner = "plugin-engine"
    func stop() { actions.removeAll { $0.ownerID != Self.extensionOwner }; BridgeRegistry.unregister("actions") }

    func start() {
        BridgeRegistry.register("actions", functions: ["register"]) { [weak self] fn, args, pluginID, reply in
            guard fn == "register", let rows = args.first as? [[String: Any]],
                  let ownerID = args.dropFirst().first as? String, rows.count <= 100 else {
                reply(nil, "Expected up to 100 actions with an id and title")
                return
            }
            self?.register(rows, pluginID: pluginID, ownerID: ownerID, reply: reply)
        }
    }

    func register(_ rows: [[String: Any]], pluginID: String, ownerID: String, reply: @escaping (Any?, String?) -> Void) {
        guard rows.count <= 100 else { return reply(nil, "Expected up to 100 actions") }
        var seen = Set<String>()
        var next: [Action] = []
        for row in rows {
            guard let id = row["id"] as? String, !id.isEmpty, id.count <= 128,
                  let title = row["title"] as? String, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  title.count <= 160, seen.insert(id).inserted else {
                reply(nil, "Action ids must be unique and nonempty; each action needs a title")
                return
            }
            next.append(Action(id: id, title: title, subtitle: String((row["subtitle"] as? String ?? "").prefix(240)),
                               shortcut: String((row["shortcut"] as? String ?? "").prefix(40)), pluginID: pluginID, ownerID: ownerID))
        }
        actions.removeAll { $0.ownerID == ownerID && $0.pluginID == pluginID }
        actions.append(contentsOf: next)
        reply(NSNull(), nil)
    }

    func remove(ownerID: String, pluginID: String? = nil) {
        actions.removeAll { $0.ownerID == ownerID && (pluginID == nil || $0.pluginID == pluginID) }
    }

    static func matches(_ shortcut: String, event: NSEvent) -> Bool {
        var text = shortcut.lowercased().replacingOccurrences(of: " ", with: "")
        var flags: NSEvent.ModifierFlags = []
        let names: [(String, NSEvent.ModifierFlags)] = [
            ("command+", .command), ("cmd+", .command), ("⌘", .command),
            ("control+", .control), ("ctrl+", .control), ("⌃", .control),
            ("option+", .option), ("alt+", .option), ("⌥", .option),
            ("shift+", .shift), ("⇧", .shift),
        ]
        for (name, flag) in names where text.contains(name) {
            flags.insert(flag)
            text = text.replacingOccurrences(of: name, with: "")
        }
        guard !flags.intersection([.command, .control, .option]).isEmpty else { return false }
        let key = event.keyCode == 49 ? "space" : event.keyCode == 36 ? "enter" : event.charactersIgnoringModifiers?.lowercased() ?? ""
        return flags == event.modifierFlags.intersection([.command, .control, .option, .shift]) && text == key
    }
}

enum KeyboardSearch {
    /// Subsequence matching, favoring contiguous words and word beginnings.
    static func score(_ query: String, in text: String) -> Int? {
        let query = Array(query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).filter { !$0.isWhitespace })
        let text = Array(text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current))
        return score(query, in: text)
    }

    /// Prepared strings let the launcher reuse the palette matcher without folding 500 titles per keystroke.
    static func score(_ query: [Character], in text: [Character]) -> Int? {
        guard !query.isEmpty else { return 0 }
        var cursor = 0, score = 0, previous = -2
        for letter in query {
            guard let index = text.indices.dropFirst(cursor).first(where: { text[$0] == letter }) else { return nil }
            score += index == previous + 1 ? 12 : 1
            if index == 0 || !text[index - 1].isLetter { score += 8 }
            score -= index - cursor
            cursor = index + 1
            previous = index
        }
        return score
    }
}
