import AppKit
import CryptoKit

enum ClipPreferences {
    static let enabled = "clips.enabled"
    static let days = "clips.days"
    static let maxItems = "clips.maxItems"
    static let ignoredApps = "clips.ignoredApps"
    static let folder = "clips.screenshotsFolder"
    static let ocr = "clips.ocr"
    static let defaultIgnoredApps = "1Password\nBitwarden\nKeychain Access\ncom.agilebits.onepassword7\ncom.1password.1password\ncom.bitwarden.desktop\ncom.apple.keychainaccess"

    static func register() {
        PluginDefaults.standard.register(defaults: [enabled: true, days: 30, maxItems: 500,
            ignoredApps: defaultIgnoredApps, folder: "", ocr: true])
    }

    static func ignores(name: String, bundleID: String, list: String) -> Bool {
        list.split(whereSeparator: \.isNewline).contains {
            let value = $0.trimmingCharacters(in: .whitespaces).lowercased()
            return !value.isEmpty && (value == name.lowercased() || value == bundleID.lowercased())
        }
    }
}

struct ClipEntry: Codable, Identifiable {
    enum Kind: String, Codable { case text, link, image, files, color, screenshot, recording }
    var id = UUID().uuidString
    var kind: Kind
    var text = ""
    var paths: [String] = []
    var date = Date()
    var source = ""
    var pinned = false
    var fingerprint = ""
    var modifiedAt: Date?
    var ocrText: String?

    var title: String {
        if !paths.isEmpty { return paths.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", ") }
        return String(text.prefix(160))
    }
    var urls: [URL] { paths.map { URL(fileURLWithPath: $0) } }
    var payload: [String: Any] {
        ["id": id, "kind": kind.rawValue, "text": String(text.prefix(16000)), "name": title,
         "paths": Array(paths.prefix(32)), "date": date.timeIntervalSince1970 * 1000,
         "source": source, "pinned": pinned, "hasFile": !paths.isEmpty,
         "ocrText": String((ocrText ?? "").prefix(16000)), "modifiedAt": (modifiedAt?.timeIntervalSince1970 ?? 0) * 1000]
    }

    static func sorted(_ entries: [ClipEntry]) -> [ClipEntry] {
        entries.sorted { a, b in
            if a.pinned != b.pinned { return a.pinned }
            if a.date != b.date { return a.date > b.date }
            return a.id < b.id
        }
    }

    static func retained(_ entries: [ClipEntry], days: Int, maxItems: Int, now: Date = Date()) -> [ClipEntry] {
        let cutoff = now.addingTimeInterval(-Double(max(1, days)) * 86_400)
        var count = 0
        return sorted(entries).filter { entry in
            if entry.pinned { return true }
            guard entry.date >= cutoff, count < max(1, maxItems) else { return false }
            count += 1
            return true
        }
    }

    static func inserting(_ captured: ClipEntry, into entries: [ClipEntry]) -> [ClipEntry] {
        var entries = entries
        if let index = entries.firstIndex(where: { $0.fingerprint == captured.fingerprint }) {
            var previous = entries.remove(at: index)
            previous.date = captured.date
            previous.source = captured.source
            entries.insert(previous, at: 0)
        } else { entries.insert(captured, at: 0) }
        return entries
    }

    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

/// All clauses are ANDed; quoted values allow spaces. Dates use the user's local calendar.
struct ClipFilter {
    private var clauses: [(String, String)] = []

    init(_ query: String) {
        let pattern = #"(?:(name|text|date):)?(?:"([^"]*)"|(\S+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return }
        for match in regex.matches(in: query, range: NSRange(query.startIndex..., in: query)) {
            let value = { (index: Int) -> String in Range(match.range(at: index), in: query).map { String(query[$0]) } ?? "" }
            clauses.append((value(1).lowercased(), value(2).isEmpty ? value(3) : value(2)))
        }
    }

    func matches(_ entry: ClipEntry, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        clauses.allSatisfy { key, value in
            if key == "date" {
                let start = calendar.startOfDay(for: now)
                let target: Date?
                switch value.lowercased() {
                case "today": target = start
                case "yesterday": target = calendar.date(byAdding: .day, value: -1, to: start)
                default:
                    let formatter = DateFormatter()
                    formatter.calendar = calendar
                    formatter.locale = Locale(identifier: "en_US_POSIX")
                    formatter.timeZone = calendar.timeZone
                    formatter.dateFormat = "yyyy-MM-dd"
                    formatter.isLenient = false
                    target = formatter.date(from: value).flatMap { formatter.string(from: $0) == value ? $0 : nil }
                }
                return target.map { calendar.isDate(entry.date, inSameDayAs: $0) } ?? false
            }
            let haystack: String
            switch key {
            case "name": haystack = entry.title
            case "text": haystack = entry.text + " " + (entry.ocrText ?? "")
            default: haystack = [entry.title, entry.text, entry.ocrText ?? "", entry.source, entry.paths.joined(separator: " ")].joined(separator: " ")
            }
            return haystack.localizedCaseInsensitiveContains(value)
        }
    }
}

/// Reads a snapshot only after checking *every* item for password-manager markers.
enum ClipCapture {
    static let privateTypes: Set<String> = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType"]
    static let maxBytes = 32 * 1024 * 1024

    struct Snapshot {
        var entry: ClipEntry
        var image: Data?
    }

    static func read(_ board: NSPasteboard, source: String) -> Snapshot? {
        let types = Set((board.types ?? []).map(\.rawValue) + (board.pasteboardItems ?? []).flatMap { $0.types.map(\.rawValue) })
        guard privateTypes.isDisjoint(with: types) else { return nil }
        let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !urls.isEmpty {
            var entry = ClipEntry(kind: .files, paths: urls.map(\.path), source: source)
            entry.fingerprint = "files:" + ClipEntry.hash(Data(entry.paths.sorted().joined(separator: "\u{0}").utf8))
            return Snapshot(entry: entry)
        }
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = board.data(forType: type), !data.isEmpty, data.count <= maxBytes {
                return Snapshot(entry: ClipEntry(kind: .image, source: source), image: data)
            }
        }
        if types.contains(NSPasteboard.PasteboardType.color.rawValue),
           let color = NSColor(from: board)?.usingColorSpace(.sRGB) {
            var text = String(format: "#%02X%02X%02X", Int((color.redComponent * 255).rounded()),
                              Int((color.greenComponent * 255).rounded()), Int((color.blueComponent * 255).rounded()))
            if color.alphaComponent < 1 { text += String(format: "%02X", Int((color.alphaComponent * 255).rounded())) }
            return textSnapshot(text, source: source, kind: .color)
        }
        var plain = board.string(forType: .string) ?? board.string(forType: .URL)
        if plain == nil, let rich = board.data(forType: .rtf), rich.count <= maxBytes {
            plain = NSAttributedString(rtf: rich, documentAttributes: nil)?.string
        }
        if plain == nil, let rich = board.data(forType: .rtfd), rich.count <= maxBytes {
            plain = NSAttributedString(rtfd: rich, documentAttributes: nil)?.string
        }
        guard let text = plain, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= 1_048_576 else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind: ClipEntry.Kind
        if trimmed.range(of: #"^#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$"#, options: .regularExpression) != nil { kind = .color }
        else if !trimmed.contains(where: \.isWhitespace), let url = URL(string: trimmed),
                ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") { kind = .link }
        else { kind = .text }
        return textSnapshot(text, source: source, kind: kind)
    }

    private static func textSnapshot(_ text: String, source: String, kind: ClipEntry.Kind) -> Snapshot {
        var entry = ClipEntry(kind: kind, text: text, source: source)
        entry.fingerprint = kind.rawValue + ":" + ClipEntry.hash(Data(text.utf8))
        return Snapshot(entry: entry)
    }
}
