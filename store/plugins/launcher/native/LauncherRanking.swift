import Foundation

/// Pure query/ranking policy. No application discovery, preferences, or UI side effects.
enum LauncherSource: String, CaseIterable, Codable {
    case applications, aiCommands, plugins, actions, system, files, askAI

    var title: String {
        switch self {
        case .applications: return "Applications"
        case .aiCommands: return "AI Commands"
        case .plugins: return "Plugins & Tab Groups"
        case .actions: return "Plugin Actions"
        case .system: return "System Commands"
        case .files: return "Files"
        case .askAI: return "Quick AI"
        }
    }
}

struct LauncherQuery: Equatable {
    let text: String
    let source: LauncherSource?
    let characters: [Character]

    init(_ raw: String) {
        let input = String(raw.prefix(512)).trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes: [(String, LauncherSource)] = [("app:", .applications), ("ai:", .aiCommands),
            ("plugin:", .plugins), ("action:", .actions), ("command:", .system), ("file:", .files), ("f ", .files)]
        if let prefix = prefixes.first(where: { input.lowercased().hasPrefix($0.0) }) {
            source = prefix.1
            text = String(input.dropFirst(prefix.0.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else { source = nil; text = input }
        characters = Array(Self.fold(text).filter { !$0.isWhitespace })
    }

    static func fold(_ string: String) -> String {
        string.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}

struct LauncherUsage: Codable, Equatable {
    var count: Int
    var lastUsed: TimeInterval

    func score(at now: TimeInterval) -> Double {
        let days = max(0, now - lastUsed) / 86_400
        return min(40, log2(Double(max(0, count)) + 1) * 7) + 40 / (1 + days / 7)
    }

    static func record(_ id: String, in history: inout [String: Self], at now: TimeInterval) {
        history[id] = Self(count: min(1_000_000, max(0, history[id]?.count ?? 0) + 1), lastUsed: now)
        if history.count > 500 {
            let keep = Set(history.sorted { $0.value.score(at: now) > $1.value.score(at: now) }.prefix(500).map(\.key))
            history = history.filter { keep.contains($0.key) }
        }
    }
}

struct LauncherSearchDocument {
    let id: String
    let source: LauncherSource
    let title: [Character]
    let detail: [Character]

    init(id: String, source: LauncherSource, title: String, detail: String = "") {
        self.id = id
        self.source = source
        self.title = Array(LauncherQuery.fold(title))
        self.detail = Array(LauncherQuery.fold(detail))
    }
}

enum LauncherRanking {
    /// Match classes dominate history: prefix > word start > subsequence > detail-only.
    /// The shared ⌘K matcher breaks ties within a class; usage never promotes an inferior class.
    static func score(_ query: LauncherQuery, document: LauncherSearchDocument, usage: LauncherUsage?, now: TimeInterval) -> Double? {
        guard query.source == nil || query.source == document.source else { return nil }
        let recent = usage?.score(at: now) ?? 0
        guard !query.characters.isEmpty else { return recent }
        let q = query.characters, title = document.title
        let compact = title.filter { !$0.isWhitespace }
        let tier: Double
        let fuzzy: Int
        if let match = KeyboardSearch.score(q, in: title) {
            fuzzy = match
            if compact.starts(with: q) { tier = 4 }
            else if title.indices.contains(where: { index in
                (index == 0 || !title[index - 1].isLetter && !title[index - 1].isNumber) && title[index...].starts(with: q)
            }) { tier = 3 }
            else { tier = 2 }
        } else if document.source != .applications, let match = KeyboardSearch.score(q, in: document.detail) { tier = 1; fuzzy = match }
        else { return nil }
        return tier * 1000 + Double(min(200, max(-200, fuzzy))) + recent
    }

    static func ranked(_ documents: [LauncherSearchDocument], query: LauncherQuery, history: [String: LauncherUsage], now: TimeInterval) -> [String] {
        documents.enumerated().compactMap { index, item -> (String, Double, Int)? in
            guard let value = score(query, document: item, usage: history[item.id], now: now) else { return nil }
            return (item.id, value, index)
        }.sorted { $0.1 == $1.1 ? $0.2 < $1.2 : $0.1 > $1.1 }.map { $0.0 }
    }
}
