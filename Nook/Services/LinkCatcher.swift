import AppKit

/// Saves links you copy (any app) into the Links plugin's storage, even while its tab has never been opened.
/// The plugin shows and manages them; its settings (capture mode, tracking params, ignored domains, max) are read here.
final class LinkCatcher {
    static let pluginID = "links"
    private static let storageKey = "links"
    private static let tracking: Set<String> = ["fbclid", "gclid", "dclid", "msclkid", "mc_cid", "mc_eid", "igshid", "si", "ref_src", "_hsenc", "_hsmi", "yclid"]

    private var changeCount = NSPasteboard.general.changeCount
    /// AI Commands copy/paste through the clipboard briefly; ignore those changes.
    static var ignoreClipboardUntil = Date.distantPast
    private var timer: Timer?
    private let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    func start() {
        guard timer == nil else { return }
        changeCount = NSPasteboard.general.changeCount
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.check() }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func check() {
        let board = NSPasteboard.general
        guard board.changeCount != changeCount else { return }
        changeCount = board.changeCount
        guard Date() > Self.ignoreClipboardUntil else { return }

        guard let tab = Services.shared.plugins.tabs.first(where: { $0.id == Self.pluginID }),
              !Prefs.disabledTabSet.contains(Self.pluginID) else { return }
        // Password managers mark secrets as concealed/transient — never look at those.
        let types = Set((board.types ?? []).map(\.rawValue))
        if types.contains("org.nspasteboard.ConcealedType") || types.contains("org.nspasteboard.TransientType") { return }

        let settings = PluginSettingsStore.values(for: tab)
        let mode = settings["capture"]?.string ?? "Only when I copy just a link"
        guard mode != "Off", let text = board.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }

        var urls: [URL] = []
        if mode.hasPrefix("Only") {
            if !text.contains(where: \.isWhitespace), let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                urls = [url]
            }
        } else {
            let range = NSRange(text.startIndex..., in: text)
            urls = (detector?.matches(in: text, range: range) ?? []).compactMap(\.url)
                .filter { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }
                .prefix(20).map { $0 }
        }
        guard !urls.isEmpty else { return }

        let ignored = Set((settings["ignoreDomains"]?.string ?? "").split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty })
        let strip = settings["stripTracking"]?.bool ?? true
        let maxLinks = Int(settings["maxLinks"]?.number ?? 1000)
        let source = NSWorkspace.shared.frontmostApplication?.localizedName

        let storage = PluginStorage(Self.pluginID)
        var list = storage.get(Self.storageKey) as? [[String: Any]] ?? []
        var toTitle: [String] = []
        for raw in urls {
            let url = strip ? Self.stripTracking(raw) : raw
            let host = (url.host ?? "").lowercased().replacingOccurrences(of: "www.", with: "")
            guard !host.isEmpty, !ignored.contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { continue }
            let key = url.absoluteString
            let now = Int(Date().timeIntervalSince1970 * 1000)
            if let i = list.firstIndex(where: { ($0["url"] as? String) == key }) {
                var entry = list.remove(at: i) // copied again → bump to the top
                entry["addedAt"] = now
                entry["count"] = (entry["count"] as? Int ?? 1) + 1
                list.insert(entry, at: 0)
            } else {
                let id = UUID().uuidString
                list.insert(["id": id, "url": key, "title": NSNull(), "domain": host, "addedAt": now, "count": 1, "source": source ?? NSNull()], at: 0)
                toTitle.append(id)
            }
        }
        // Over the limit: drop the oldest links that aren't pinned (pinned ones are never trimmed).
        while list.count > maxLinks, let last = list.lastIndex(where: { ($0["pinned"] as? Bool) != true }) {
            list.remove(at: last)
        }
        storage.set(Self.storageKey, list)
        PluginEvents.emit("links", list, to: Self.pluginID)
        for id in toTitle { fetchTitle(id) }
    }

    /// Fill in the page title in the background (first <title> or og:title).
    private func fetchTitle(_ id: String) {
        let storage = PluginStorage(Self.pluginID)
        guard let entry = (storage.get(Self.storageKey) as? [[String: Any]])?.first(where: { $0["id"] as? String == id }),
              let urlString = entry["url"] as? String, let url = URL(string: urlString) else { return }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        URLSession(configuration: .ephemeral).dataTask(with: request) { data, _, _ in
            guard let data, let html = String(data: data.prefix(400_000), encoding: .utf8) ?? String(data: data.prefix(400_000), encoding: .isoLatin1),
                  let title = Self.title(in: html) else { return }
            DispatchQueue.main.async {
                var list = storage.get(Self.storageKey) as? [[String: Any]] ?? []
                guard let i = list.firstIndex(where: { $0["id"] as? String == id }) else { return }
                list[i]["title"] = title
                storage.set(Self.storageKey, list)
                PluginEvents.emit("links", list, to: Self.pluginID)
            }
        }.resume()
    }

    private static func title(in html: String) -> String? {
        let patterns = [#"<meta[^>]+property=["']og:title["'][^>]+content=["']([^"']+)"#, #"<title[^>]*>([^<]+)</title>"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let range = Range(match.range(at: 1), in: html) else { continue }
            let clean = decodeEntities(String(html[range])).trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty { return String(clean.prefix(200)) }
        }
        return nil
    }

    /// Enough HTML entity decoding for page titles (runs off the main thread, so no NSAttributedString).
    private static func decodeEntities(_ s: String) -> String {
        var out = s
        for (entity, char) in ["&amp;": "&", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&lt;": "<", "&gt;": ">", "&nbsp;": " ", "&#x27;": "'", "&#8217;": "’", "&#8211;": "–", "&#8212;": "—", "&mdash;": "—", "&ndash;": "–"] {
            out = out.replacingOccurrences(of: entity, with: char)
        }
        if let regex = try? NSRegularExpression(pattern: "&#(\\d+);") {
            for match in regex.matches(in: out, range: NSRange(out.startIndex..., in: out)).reversed() {
                guard let whole = Range(match.range, in: out), let num = Range(match.range(at: 1), in: out),
                      let code = UInt32(out[num]), let scalar = Unicode.Scalar(code) else { continue }
                out.replaceSubrange(whole, with: String(Character(scalar)))
            }
        }
        return out
    }

    static func stripTracking(_ url: URL) -> URL {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false), let items = parts.queryItems else { return url }
        let kept = items.filter { !$0.name.lowercased().hasPrefix("utm_") && !tracking.contains($0.name.lowercased()) }
        parts.queryItems = kept.isEmpty ? nil : kept
        return parts.url ?? url
    }
}
