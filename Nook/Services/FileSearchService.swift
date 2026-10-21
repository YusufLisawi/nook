import AppKit
import AppIntents
import SwiftUI
import WebKit

/// Query lifecycle stays on the main run loop; metadata reads run off the UI thread.
final class FileSearchService {
    static let shared = FileSearchService()
    private var sessions: [String: FileSearchSession] = [:]
    private var defaultsObserver: NSObjectProtocol?
    private var shortcutMonitor: Any?
    private let defaults: UserDefaults
    private var preferences: FileSearchPreferences.Snapshot
    private var cache: [String: [FileSearchResult]] = [:]
    private var recentQueries: [String] = []
    private var usage: [String: Int]
    private let previews = FileSearchPreview()
    private let quickLook = FileSearchQuickLook()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        preferences = FileSearchPreferences.Snapshot(defaults: defaults)
        usage = defaults.dictionary(forKey: FileSearchPreferences.usageKey) as? [String: Int] ?? [:]
    }

    func register() {
        guard defaultsObserver == nil else { return }
        BridgeRegistry.register("files", functions: ["search", "cancel", "keepAlive", "preview", "open", "reveal", "quickLook", "copyPath", "copyFile", "openWith"]) { [weak self] fn, args, pluginID, reply in
            self?.handle(fn, args: args, pluginID: pluginID, reply: reply)
        }
        SettingsRegistry.register(id: "files", title: "File Search", symbol: "doc.text.magnifyingglass", tint: .blue, order: 46) { FileSearchSettingsPane() }
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            let updated = FileSearchPreferences.Snapshot(defaults: self.defaults)
            guard updated != self.preferences else { return }
            self.preferences = updated
            self.cache.removeAll()
            self.recentQueries.removeAll()
            for session in Array(self.sessions.values) { session.cancel() }
            self.sessions.removeAll()
            PluginEvents.emit("filesSettings", ["scope": updated.scope])
        }
        // NSPanel's edit-menu routing consumes Command-C before WebKit can see it.
        // Intercept only this bundled tab, only while its web view is the first responder.
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
            guard flags == .command || flags == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "c" else { return event }
            var view = NSApp.keyWindow?.firstResponder as? NSView
            while let current = view {
                if let web = current as? WKWebView, web.url?.deletingLastPathComponent().lastPathComponent == "files" {
                    web.evaluateJavaScript("window.nook && nook._emit('filesShortcut', '\(flags.contains(.shift) ? "copyFile" : "copyPath")')")
                    return nil
                }
                view = current.superview
            }
            return event
        }
    }

    private func handle(_ fn: String, args: [Any], pluginID: String, reply: @escaping (Any?, String?) -> Void) {
        if fn == "search" {
            let options = args.count > 1 ? args[1] as? [String: Any] ?? [:] : [:]
            let client = String((options["clientID"] as? String ?? "default").prefix(100))
            let key = pluginID + ":" + client
            sessions.removeValue(forKey: key)?.cancel()
            let query = String((args.first as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(256))
            let requestedScope = options["scope"] as? String ?? preferences.scope
            let scope = FileSearchPreferences.scopes.contains(requestedScope) ? requestedScope : preferences.scope
            let requestedKind = options["kind"] as? String ?? "all"
            let kind = FileSearchPreferences.kinds.contains(requestedKind) ? requestedKind : "all"
            let cacheKey = scope + ":" + kind
            let exactKey = cacheKey + ":" + FileSearchPolicy.folded(query)
            let session = FileSearchSession(query: query, scope: scope, kind: kind, preferences: preferences,
                                            limit: min(100, max(1, options["limit"] as? Int ?? 60)), usage: usage,
                                            clientID: client, requestID: String(describing: options["requestID"] ?? ""))
            // Bound forgotten clients (e.g. plugin reloads) without mixing screens' requests.
            if sessions.count >= 16, let oldest = sessions.min(by: { $0.value.created < $1.value.created })?.key { sessions.removeValue(forKey: oldest)?.cancel() }
            sessions[key] = session
            session.emit = { [weak self, weak session] results, payload in
                guard let self, let session, self.sessions[key] === session else { return }
                if !results.isEmpty {
                    let fresh = Array(results.prefix(500))
                    let paths = Set(fresh.map(\.path))
                    self.cache[cacheKey] = Array((fresh + (self.cache[cacheKey] ?? []).filter { !paths.contains($0.path) }).prefix(1500))
                    self.cache[exactKey] = fresh
                    self.recentQueries.removeAll { $0 == exactKey }
                    self.recentQueries.append(exactKey)
                    if self.recentQueries.count > 32 { self.cache.removeValue(forKey: self.recentQueries.removeFirst()) }
                } else if payload["gathering"] as? Bool == false {
                    self.cache.removeValue(forKey: exactKey)
                }
                PluginEvents.emit("files", payload, to: pluginID)
            }
            session.expired = { [weak self, weak session] in
                guard let self, let session, self.sessions[key] === session else { return }
                self.sessions.removeValue(forKey: key)
            }
            let initial = session.payload(results: session.ranked(cache[exactKey] ?? cache[cacheKey] ?? []), gathering: true)
            reply(initial, nil)
            session.schedule()
            return
        }
        if fn == "cancel" {
            let client = String((args.first as? String ?? "default").prefix(100))
            sessions.removeValue(forKey: pluginID + ":" + client)?.cancel()
            reply(NSNull(), nil)
            return
        }
        if fn == "keepAlive" {
            let client = String((args.first as? String ?? "default").prefix(100))
            reply(sessions[pluginID + ":" + client]?.touch() ?? false, nil)
            return
        }
        do {
            let url = try FileSearchPreview.fileURL(args.first as? String ?? "")
            switch fn {
            case "preview": previews.load(url, reply: reply)
            case "open":
                guard NSWorkspace.shared.open(url) else { throw FileSearchError.message("No application could open this file.") }
                recordUse(url.path); reply(NSNull(), nil)
            case "reveal": NSWorkspace.shared.activateFileViewerSelecting([url]); reply(NSNull(), nil)
            case "quickLook": quickLook.show(url); reply(NSNull(), nil)
            case "copyPath":
                NSPasteboard.general.clearContents()
                guard NSPasteboard.general.setString(url.path, forType: .string) else { throw FileSearchError.message("Couldn't copy the path. Try again.") }
                reply(NSNull(), nil)
            case "copyFile":
                NSPasteboard.general.clearContents()
                guard NSPasteboard.general.writeObjects([url as NSURL]) else { throw FileSearchError.message("Couldn't copy the file. Try again.") }
                reply(NSNull(), nil)
            case "openWith":
                if args.count > 1, let path = args[1] as? String, !path.isEmpty {
                    let app = try FileSearchPreview.fileURL(path)
                    guard (try app.resourceValues(forKeys: [.contentTypeKey])).contentType?.conforms(to: .application) == true else { throw FileSearchError.message("Choose an application bundle.") }
                    NSWorkspace.shared.open([url], withApplicationAt: app, configuration: .init()) { [weak self] _, error in
                        DispatchQueue.main.async {
                            if let error { reply(nil, error.localizedDescription) }
                            else { self?.recordUse(url.path); reply(NSNull(), nil) }
                        }
                    }
                } else {
                    reply(NSWorkspace.shared.urlsForApplications(toOpen: url).map { ["path": $0.path, "name": $0.deletingPathExtension().lastPathComponent] }, nil)
                }
            default: reply(nil, "Unknown files call: \(fn)")
            }
        } catch { reply(nil, error.localizedDescription) }
    }

    private func recordUse(_ path: String) {
        usage[path] = min(1000, (usage[path] ?? 0) + 1)
        if usage.count > 200, let least = usage.min(by: { $0.value < $1.value })?.key { usage.removeValue(forKey: least) }
        defaults.set(usage, forKey: FileSearchPreferences.usageKey)
        NSDocumentController.shared.noteNewRecentDocumentURL(URL(fileURLWithPath: path))
    }
}

private final class FileSearchSession {
    private static let metadataWorker = DispatchQueue(label: "com.yusuf.nook.files.metadata", qos: .userInitiated, attributes: .concurrent)
    let created = Date()
    private let queryText: String
    private let scope: String
    private let kind: String
    private let preferences: FileSearchPreferences.Snapshot
    private let limit: Int
    private let usage: [String: Int]
    private let clientID: String
    private let requestID: String
    private let query = NSMetadataQuery()
    private var observers: [NSObjectProtocol] = []
    private var debounce: DispatchWorkItem?
    private var stopped = false
    private var scanning = false
    private var scanAgain = false
    private var locked = false
    private var truncated = false
    private var candidates: [FileSearchResult] = []
    private var seenPaths: Set<String> = []
    private var lastPublish = Date.distantPast
    private var lastActivity = Date()
    private var expiry: Timer?
    var emit: (([FileSearchResult], [String: Any]) -> Void)?
    var expired: (() -> Void)?

    init(query: String, scope: String, kind: String, preferences: FileSearchPreferences.Snapshot, limit: Int, usage: [String: Int], clientID: String, requestID: String) {
        queryText = query; self.scope = scope; self.kind = kind; self.preferences = preferences
        self.limit = limit; self.usage = usage; self.clientID = clientID; self.requestID = requestID
    }

    func schedule() {
        let work = DispatchWorkItem { [weak self] in self?.start() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(25), execute: work)
    }

    func touch() -> Bool {
        guard !stopped else { return false }
        lastActivity = Date()
        return true
    }

    func cancel() {
        stopped = true
        debounce?.cancel()
        expiry?.invalidate(); expiry = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }; observers.removeAll()
        if locked { query.enableUpdates(); locked = false }
        query.stop()
    }

    private func start() {
        guard !stopped else { return }
        query.predicate = FileSearchPolicy.predicate(query: queryText, kind: kind)
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch scope {
        case "Developer", "Downloads": query.searchScopes = [home.appendingPathComponent(scope)]
        case "all": query.searchScopes = [NSMetadataQueryIndexedLocalComputerScope]
        default: query.searchScopes = [NSMetadataQueryUserHomeScope]
        }
        query.notificationBatchingInterval = 0.025
        query.sortDescriptors = queryText.isEmpty ? [NSSortDescriptor(key: "kMDItemLastUsedDate", ascending: false)] : []
        query.operationQueue = .main
        for name in [Notification.Name.NSMetadataQueryGatheringProgress, .NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: query, queue: .main) { [weak self] _ in self?.scan() })
        }
        guard query.start() else {
            var result = payload(results: [], gathering: false)
            result["error"] = "Spotlight couldn't start. Check Spotlight Search Privacy in System Settings."
            emit?([], result); cancel(); return
        }
        // Fallback for early results when Spotlight hasn't posted its progress notification yet.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(25)) { [weak self] in self?.scan() }
        expiry = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self, Date().timeIntervalSince(self.lastActivity) > 120 else { return }
            self.cancel() // abandoned web views must not retain a live Spotlight query forever
            self.expired?()
        }
    }

    func ranked(_ results: [FileSearchResult]) -> [FileSearchResult] {
        FileSearchPolicy.ranked(results, query: queryText, preferences: preferences, usage: usage)
    }

    func payload(results: [FileSearchResult], gathering: Bool) -> [String: Any] {
        ["clientID": clientID, "requestID": requestID, "query": queryText, "scope": scope, "kind": kind,
         "results": Array(results.prefix(limit)).map(\.json), "gathering": gathering, "truncated": truncated,
         "elapsedMs": Int(Date().timeIntervalSince(created) * 1000)]
    }

    private func scan() {
        guard !stopped else { return }
        guard !scanning else { scanAgain = true; return }
        scanning = true
        query.disableUpdates(); locked = true
        let count = min(query.resultCount, 20_000)
        truncated = query.resultCount > count
        candidates = []
        seenPaths.removeAll(keepingCapacity: true)
        scanChunk(index: 0, count: count)
    }

    private func scanChunk(index: Int, count: Int) {
        guard !stopped else { return }
        let end = min(index + (index == 0 ? 20 : 100), count)
        let items = (index..<end).compactMap { query.result(at: $0) as? NSMetadataItem }
        let preferences = preferences
        // Metadata can require IPC or disk access. Keep the frozen query on main, and read
        // only its independent item references here so typing and cancellation stay responsive.
        Self.metadataWorker.async { [weak self] in
            let results = items.compactMap { item -> FileSearchResult? in
                guard let path = item.value(forAttribute: "kMDItemPath") as? String, preferences.allows(path) else { return nil }
                return FileSearchResult(item: item, knownPath: path)
            }
            DispatchQueue.main.async { self?.scanned(results, first: index == 0, end: end, count: count) }
        }
    }

    private func scanned(_ results: [FileSearchResult], first: Bool, end: Int, count: Int) {
        guard !stopped else { return }
        candidates.append(contentsOf: results.filter { seenPaths.insert($0.path).inserted })
        if first || end == count || Date().timeIntervalSince(lastPublish) > 0.05 {
            candidates = Array(ranked(candidates).prefix(500))
            emit?(candidates, payload(results: candidates, gathering: query.isGathering || end < count))
            guard !stopped else { return } // event consumers can cancel synchronously
            lastPublish = Date()
        }
        if end < count {
            DispatchQueue.main.async { [weak self] in self?.scanChunk(index: end, count: count) }
        } else {
            scanning = false
            locked = false; query.enableUpdates()
            if scanAgain { scanAgain = false; DispatchQueue.main.async { [weak self] in self?.scan() } }
        }
    }
}
