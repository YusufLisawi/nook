import Foundation
import Darwin

enum FileIndexPath {
    /// Foundation intentionally rewrites /private/tmp back to /tmp. FSEvents uses the
    /// physical spelling, so catalog roots/scopes use realpath, including missing tails.
    static func canonical(_ path: String) -> String {
        if let resolved = realpath(path, nil) { defer { free(resolved) }; return String(cString: resolved) }
        guard path != "/", path.hasPrefix("/") else { return path }
        let parent = (path as NSString).deletingLastPathComponent
        return canonical(parent) + (parent == "/" ? "" : "/") + (path as NSString).lastPathComponent
    }
    /// Preserve the final symlink's identity when updating an indexed file reference.
    static func file(_ path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        return canonical(parent) + (parent == "/" ? "" : "/") + (path as NSString).lastPathComponent
    }
}

/// Bounded query compiler: OR groups of AND atoms, shared by the tab, bridge and launcher.
struct FileIndexQuery {
    struct Atom: Equatable {
        let group: Int
        let type: Int
        let text: String
        let number: Double
    }
    let raw: String
    let atoms: [Atom]
    let highlightTerms: [String]

    enum Invalid: LocalizedError {
        case syntax(String)
        var errorDescription: String? { if case let .syntax(message) = self { return message }; return nil }
    }

    static let kindMasks: [String: UInt32] = ["all": 511, "folder": 2, "app": 4, "image": 8, "pdf": 16,
        "code": 32, "video": 64, "audio": 128, "archive": 256, "doc": 17, "document": 17]

    init(_ input: String, now: Date = Date(), calendar: Calendar = .current) throws {
        guard input.utf8.count <= 2048 else { throw Invalid.syntax("Use a shorter query (up to 2,048 bytes).") }
        raw = input
        var tokens: [String] = [], token = "", quoted = false
        for character in input {
            if character == "\"" { quoted.toggle() }
            else if character.isWhitespace && !quoted {
                if !token.isEmpty { tokens.append(token); token = "" }
            } else if character == "|" && !quoted && !token.hasPrefix("kind:") && !token.hasPrefix("!kind:") {
                if !token.isEmpty { tokens.append(token); token = "" }; tokens.append("|")
            } else { token.append(character) }
        }
        if quoted { throw Invalid.syntax("Close the quote to search a phrase.") }
        if !token.isEmpty { tokens.append(token) }
        var result: [Atom] = [], highlights: [String] = [], group = 0, groupHasTerm = false
        func add(_ type: Int, _ text: String = "", _ number: Double = 0, negated: Bool = false) {
            result.append(Atom(group: group, type: type | (negated ? 16 : 0), text: text, number: number))
            groupHasTerm = true
        }
        for raw in tokens {
            if raw == "|" {
                guard groupHasTerm else { throw Invalid.syntax("Put a search term on each side of |.") }
                group += 1; groupHasTerm = false; continue
            }
            let negated = raw.hasPrefix("!")
            let term = negated ? String(raw.dropFirst()) : raw
            guard !term.isEmpty else { throw Invalid.syntax("Add a term after !.") }
            let lower = term.lowercased()
            if lower.hasPrefix("ext:") {
                let extensions = lower.dropFirst(4).split(separator: ";").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }.filter { !$0.isEmpty }
                guard !extensions.isEmpty else { throw Invalid.syntax("Try ext:pdf;docx.") }
                guard extensions.count <= 32 else { throw Invalid.syntax("Use at most 32 extensions in one ext: filter.") }
                add(3, extensions.joined(separator: ";"), negated: negated)
            } else if lower.hasPrefix("kind:") {
                var mask: UInt32 = 0
                for kind in lower.dropFirst(5).split(separator: "|") {
                    guard let value = Self.kindMasks[String(kind)] else { throw Invalid.syntax("Unknown kind: \(kind).") }
                    mask |= value
                }
                guard mask > 0 else { throw Invalid.syntax("Try kind:image|folder.") }
                add(4, "", Double(mask), negated: negated)
            } else if lower.hasPrefix("file:") || lower.hasPrefix("folder:") {
                let folder = lower.hasPrefix("folder:")
                add(5, "", folder ? 1 : 0, negated: negated)
                let name = String(term.dropFirst(folder ? 7 : 5))
                if !name.isEmpty { add(0, name, negated: negated); if !negated { highlights.append(name) } }
            } else if lower.hasPrefix("size:") {
                var value = String(lower.dropFirst(5))
                let comparison = value.first
                guard comparison == ">" || comparison == "<" else { throw Invalid.syntax("Use size:>10mb or size:<1gb.") }
                value.removeFirst()
                var multiplier: Double = 1
                for (suffix, scale) in [("kb", 1024.0), ("mb", 1_048_576.0), ("gb", 1_073_741_824.0), ("tb", 1_099_511_627_776.0), ("b", 1.0)] where value.hasSuffix(suffix) {
                    multiplier = scale; value.removeLast(suffix.count); break
                }
                guard let size = Double(value), size >= 0, size.isFinite, (size * multiplier).isFinite else { throw Invalid.syntax("Enter a valid file size.") }
                add(comparison == ">" ? 6 : 7, "", size * multiplier, negated: negated)
            } else if lower.hasPrefix("dm:") || lower.hasPrefix("added:") {
                let added = lower.hasPrefix("added:")
                let value = String(lower.dropFirst(added ? 6 : 3))
                let start: Date
                var end: Date?
                if value == "today" { start = calendar.startOfDay(for: now) }
                else if value == "week" { start = calendar.date(byAdding: .day, value: -7, to: now) ?? now }
                else {
                    let formatter = DateFormatter(); formatter.calendar = calendar; formatter.locale = Locale(identifier: "en_US_POSIX")
                    formatter.timeZone = calendar.timeZone; formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
                    guard let date = formatter.date(from: value), formatter.string(from: date) == value else { throw Invalid.syntax("Use today, week, or YYYY-MM-DD.") }
                    start = date; end = calendar.date(byAdding: .day, value: 1, to: date)
                }
                // A negated calendar day is the OR of before/after; keep grammar unambiguous.
                if negated, end != nil { throw Invalid.syntax("Use !dm:today / !added:week, or a positive calendar date.") }
                add(added ? 10 : 8, "", start.timeIntervalSince1970, negated: negated)
                if let end { add(added ? 11 : 9, "", end.timeIntervalSince1970) }
            } else if term.hasPrefix("~/") || term.hasPrefix("/") {
                let path = FileIndexPath.canonical(URL(fileURLWithPath: (term as NSString).expandingTildeInPath).standardizedFileURL.path)
                add(2, path, negated: negated)
            } else if term.contains("*") || term.contains("?") {
                add(1, term, negated: negated)
                if !negated { highlights.append(contentsOf: term.split(whereSeparator: { $0 == "*" || $0 == "?" }).map(String.init)) }
            } else {
                add(0, term, negated: negated); if !negated { highlights.append(term) }
            }
        }
        guard tokens.isEmpty || groupHasTerm else { throw Invalid.syntax("Add a term after |.") }
        guard result.count <= 64 else { throw Invalid.syntax("Use at most 64 search terms.") }
        atoms = result; highlightTerms = highlights
    }

    func compiled(scope: String, kind: String, now: Date = Date()) -> OpaquePointer {
        let query = nf_query_create(scope, Self.kindMasks[kind] ?? 511, now.timeIntervalSince1970)!
        for atom in atoms { nf_query_add(query, Int32(atom.group), Int32(atom.type), atom.text, atom.number) }
        return query
    }

    /// Character indices, never HTML. Each AND/OR name atom contributes its subsequence.
    func highlights(in name: String) -> Set<Int> {
        let characters = Array(name)
        var selected = Set<Int>()
        for term in highlightTerms {
            let folded = FileSearchPolicy.folded(term)
            if let range = name.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) {
                let start = name.distance(from: name.startIndex, to: range.lowerBound)
                let end = name.distance(from: name.startIndex, to: range.upperBound)
                selected.formUnion(start..<end)
            } else {
                var remaining = Array(folded), matches: [Int] = []
                for (index, character) in characters.enumerated() where !remaining.isEmpty {
                    if FileSearchPolicy.folded(String(character)) == String(remaining[0]) { matches.append(index); remaining.removeFirst() }
                }
                if remaining.isEmpty { selected.formUnion(matches) }
            }
        }
        return selected
    }
}
