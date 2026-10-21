import Foundation

/// Bridge models and fallback policy; the packed index is in Services/Files.
enum FileSearchPreferences {
    static let scopeKey = "files.defaultScope"
    static let hiddenKey = "files.showHidden"
    static let excludedKey = "files.excludedFolders"
    static let usageKey = "files.usage"
    static let scopes = ["home", "Developer", "Downloads", "all"]
    static let kinds = ["all", "folder", "app", "document", "image", "pdf", "code", "video", "audio", "archive"]

    struct Snapshot: Equatable {
        let scope: String
        let showHidden: Bool
        let excluded: [String]

        init(defaults: PluginDefaults = .standard) {
            let stored = defaults.string(forKey: scopeKey) ?? "home"
            scope = scopes.contains(stored) ? stored : "home"
            showHidden = defaults.bool(forKey: hiddenKey)
            excluded = (defaults.string(forKey: excludedKey) ?? "").components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("/") || $0.hasPrefix("~/") }
                .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL.path }
        }

        func allows(_ path: String) -> Bool {
            let parts = path.split(separator: "/")
            guard !parts.contains("node_modules"), !parts.contains(".git") else { return false }
            if !showHidden && parts.contains(where: { $0.hasPrefix(".") }) { return false }
            for index in parts.indices where parts[index] == "Library" {
                let next = parts.index(after: index)
                if next < parts.endIndex && ["Caches", "Logs", "Developer"].contains(String(parts[next])) { return false }
            }
            return !excluded.contains { FileSearchPolicy.isInside(path, root: $0) }
        }
    }
}

enum FileSearchPolicy {
    // Spotlight's installed importers don't consistently identify TypeScript and config files.
    static let codeExtensions: Set<String> = ["swift", "m", "mm", "h", "c", "cc", "cpp", "hpp", "cs", "go", "rs",
        "py", "pyi", "rb", "php", "java", "kt", "kts", "js", "mjs", "cjs", "ts", "tsx", "jsx", "html", "htm",
        "css", "scss", "sass", "less", "json", "yaml", "yml", "toml", "xml", "sh", "zsh", "bash", "fish",
        "sql", "vue", "svelte", "lua", "pl", "r", "dart"]

    static func isInside(_ path: String, root: String) -> Bool {
        path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
    }

    static func folded(_ string: String) -> String {
        string.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    /// Tier always dominates usage, so a frequently opened substring cannot outrank a prefix.
    static func matchTier(name: String, query: String) -> Int {
        if query.isEmpty { return 0 }
        let normalizedName = folded(name), normalizedQuery = folded(query)
        if normalizedName.hasPrefix(normalizedQuery) { return 3 }
        var start = name.startIndex
        while start < name.endIndex,
              let match = name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: start..<name.endIndex) {
            if match.lowerBound == name.startIndex { return 2 }
            let previous = name[name.index(before: match.lowerBound)], current = name[match.lowerBound]
            if (!previous.isLetter && !previous.isNumber) || (previous.isLowercase && current.isUppercase) { return 2 }
            start = name.index(after: match.lowerBound)
        }
        return normalizedName.contains(normalizedQuery) ? 1 : -1
    }

    static func ranked(_ results: [FileSearchResult], query: String, preferences: FileSearchPreferences.Snapshot,
                       usage: [String: Int], now: Double = Date().timeIntervalSince1970) -> [FileSearchResult] {
        func boost(_ item: FileSearchResult) -> Double {
            let recent = max(item.added, item.modified)
            guard !query.isEmpty else { return recent }
            let days = max(0, now - item.lastUsed) / 86400
            return max(recent, item.lastUsed) + min(7 * 86400, log2(Double((usage[item.path] ?? 0) + 1)) * 86400) / (1 + days / 7)
        }
        return results.compactMap { item -> (item: FileSearchResult, tier: Int, boost: Double)? in
            guard preferences.allows(item.path), preferences.showHidden || !item.hidden else { return nil }
            let tier = matchTier(name: item.name, query: query)
            return tier < 0 ? nil : (item, tier, boost(item))
        }.sorted {
            if $0.tier != $1.tier { return $0.tier > $1.tier }
            if $0.boost != $1.boost { return $0.boost > $1.boost }
            let comparison = $0.item.name.localizedStandardCompare($1.item.name)
            return comparison == .orderedSame ? $0.item.path < $1.item.path : comparison == .orderedAscending
        }.map(\.item)
    }

    static func predicate(query: String, kind: String) -> NSPredicate {
        // Format arguments keep quotes, wildcards and predicate operators literal.
        let name = query.isEmpty
            ? NSPredicate(format: "kMDItemFSContentChangeDate > %@", Date(timeIntervalSince1970: 0) as NSDate)
            : NSPredicate(format: "kMDItemFSName CONTAINS[cd] %@", query)
        let tree: (String) -> NSPredicate = { NSPredicate(format: "kMDItemContentTypeTree == %@", $0) }
        let code = NSCompoundPredicate(orPredicateWithSubpredicates: [tree("public.source-code")] +
            codeExtensions.sorted().map { NSPredicate(format: "kMDItemFSName ENDSWITH[cd] %@", "." + $0) })
        let filter: NSPredicate
        switch kind {
        case "folder": filter = tree("public.folder")
        case "app": filter = tree("com.apple.application-bundle")
        case "image": filter = tree("public.image")
        case "pdf": filter = tree("com.adobe.pdf")
        case "code": filter = code
        case "document":
            filter = NSCompoundPredicate(andPredicateWithSubpredicates: [tree("public.content"), NSCompoundPredicate(notPredicateWithSubpredicate: NSCompoundPredicate(orPredicateWithSubpredicates: [tree("public.image"), tree("public.movie"), tree("public.audio"), code]))])
        default: return name
        }
        return NSCompoundPredicate(andPredicateWithSubpredicates: [name, filter])
    }
}

struct FileSearchResult {
    let path: String
    let name: String
    let kind: String
    let size: Int64
    let modified: Double
    let lastUsed: Double
    let contentTypes: [String]
    var hidden = false
    var added: Double = 0

    var category: String {
        if contentTypes.contains("com.apple.application-bundle") { return "app" }
        if contentTypes.contains("public.folder") { return "folder" }
        if contentTypes.contains("public.image") { return "image" }
        if contentTypes.contains("com.adobe.pdf") { return "pdf" }
        if contentTypes.contains("public.source-code") || FileSearchPolicy.codeExtensions.contains((path as NSString).pathExtension.lowercased()) { return "code" }
        if contentTypes.contains("public.movie") { return "video" }
        if contentTypes.contains("public.audio") { return "audio" }
        if contentTypes.contains("public.archive") { return "archive" }
        return "document"
    }

    var json: [String: Any] {
        ["path": path, "name": name, "kind": kind, "size": size, "modified": modified, "lastUsed": lastUsed,
         "category": category, "added": added]
    }
}

extension FileSearchResult {
    init?(item: NSMetadataItem, knownPath: String? = nil) {
        // One metadata round trip instead of a separate IPC for each displayed attribute.
        let values = item.values(forAttributes: ["kMDItemPath", "kMDItemFSName", "kMDItemKind", "kMDItemFSSize",
                                                "kMDItemFSContentChangeDate", "kMDItemLastUsedDate", "kMDItemDateAdded", "kMDItemFSCreationDate", "kMDItemContentTypeTree", "kMDItemFSInvisible"]) ?? [:]
        guard let path = knownPath ?? values["kMDItemPath"] as? String else { return nil }
        self.path = path
        name = values["kMDItemFSName"] as? String ?? (path as NSString).lastPathComponent
        kind = values["kMDItemKind"] as? String ?? "File"
        size = (values["kMDItemFSSize"] as? NSNumber)?.int64Value ?? 0
        modified = (values["kMDItemFSContentChangeDate"] as? Date)?.timeIntervalSince1970 ?? 0
        lastUsed = (values["kMDItemLastUsedDate"] as? Date)?.timeIntervalSince1970 ?? 0
        contentTypes = values["kMDItemContentTypeTree"] as? [String] ?? []
        hidden = (values["kMDItemFSInvisible"] as? NSNumber)?.boolValue ?? false
        added = (values["kMDItemDateAdded"] as? Date ?? values["kMDItemFSCreationDate"] as? Date)?.timeIntervalSince1970 ?? 0
    }

}
