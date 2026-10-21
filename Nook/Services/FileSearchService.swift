import AppKit
import AppIntents
import SwiftUI

/// Compatibility bridge and file actions. Search ownership is in FileNameIndex.
final class FileSearchService {
    static let shared = FileSearchService()
    private var sessions: [String: FileIndexClient] = [:]
    private var observers: [NSObjectProtocol] = []
    private let index: FileNameIndex
    private let defaults: UserDefaults
    private var preferences: FileSearchPreferences.Snapshot
    private let previews = FileSearchPreview()
    private let quickLook = FileSearchQuickLook()

    init(defaults: UserDefaults = .standard, index: FileNameIndex = .shared) {
        self.index = index
        self.defaults = defaults
        preferences = FileSearchPreferences.Snapshot(defaults: defaults)
    }

    func register() {
        guard observers.isEmpty else { return }
        FileSearchWebShortcuts.register()
        BridgeRegistry.register("files", functions: ["search", "cancel", "keepAlive", "preview", "open", "reveal", "quickLook", "copyPath", "copyName", "copyFile", "openWith", "trash", "status", "rebuild"]) { [weak self] fn, args, pluginID, reply in
            self?.handle(fn, args: args, pluginID: pluginID, reply: reply)
        }
        SettingsRegistry.register(id: "files", title: "File Search", symbol: "doc.text.magnifyingglass", tint: .blue, order: 46,
                                  keywords: ["index", "recent", "files", "folders", "Downloads"]) { FileSearchSettingsPane() }
        index.start(defaults: defaults)
        observers.append(NotificationCenter.default.addObserver(forName: FileNameIndex.changed, object: nil, queue: .main) { [weak self] _ in
            self?.refreshClients()
        })
        observers.append(NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            let updated = FileSearchPreferences.Snapshot(defaults: self.defaults)
            let changed = updated != self.preferences
            self.preferences = updated
            self.index.start(defaults: self.defaults)
            if changed { PluginEvents.emit("filesSettings", ["scope": updated.scope]); self.refreshClients() }
        })
    }

    func cancel(_ key: String, releaseCursor: Bool = true) {
        let session = sessions.removeValue(forKey: key)
        session?.fallback?.cancel(); session?.onCancel?()
        if releaseCursor { index.cancel(client: key) }
    }

    func search(_ text: String, options: [String: Any], pluginID: String,
                update: @escaping ([String: Any]) -> Void) {
        let client = String((options["clientID"] as? String ?? "default").prefix(100))
        let key = pluginID + ":" + client
        cancel(key, releaseCursor: false) // Preserve the complete candidate set across keystrokes.
        let scope = options["scope"] as? String ?? preferences.scope
        let kind = options["kind"] as? String ?? "all"
        let session = FileIndexClient(index: index, text: text, scope: FileSearchPreferences.scopes.contains(scope) ? scope : preferences.scope,
                                      kind: FileSearchPreferences.kinds.contains(kind) ? kind : "all", limit: min(100, max(1, options["limit"] as? Int ?? 60)),
                                      client: client, request: String(describing: options["requestID"] ?? ""), update: update)
        if sessions.count >= 24, let oldest = sessions.min(by: { $0.value.touched < $1.value.touched })?.key { cancel(oldest) }
        sessions[key] = session
        run(session, key: key)
    }

    private func refreshClients() {
        for (key, session) in sessions {
            if Date().timeIntervalSince(session.touched) > 120 && !key.hasPrefix("native.files:") { cancel(key) }
            else { run(session, key: key) }
        }
    }

    private func run(_ session: FileIndexClient, key: String) {
        session.version += 1
        let version = session.version
        if index.ready {
            session.fallback?.cancel(); session.fallback = nil
            index.search(session.text, scope: session.scope, kind: session.kind, limit: session.limit, client: key) { [weak self, weak session] result in
                guard let self, let session, self.sessions[key] === session, session.version == version else { return }
                switch result {
                case .success(let (rows, total, elapsed)):
                    session.update(session.payload(rows, total: total, elapsed: elapsed, gathering: false))
                case .failure(let error):
                    var payload = session.payload([], total: 0, elapsed: 0, gathering: false)
                    payload["error"] = error.localizedDescription; session.update(payload)
                }
            }
        } else if session.fallback == nil {
            do {
                let parsed = try FileIndexQuery(session.text)
                let fallback = FileSpotlightFallback(query: parsed.highlightTerms.first ?? "", scope: session.scope, kind: session.kind,
                    preferences: preferences, limit: session.limit, usage: [:], clientID: session.client, requestID: session.request)
                let config = FileNameIndex.Configuration(defaults: defaults)
                fallback.roots = config.roots; fallback.allowsPath = config.accepts
                let fallbackKind = session.kind
                fallback.rankResults = { FileNameIndex.rankCandidates($0, query: parsed, kind: fallbackKind) }
                session.fallback = fallback
                session.update(session.payload([], total: 0, elapsed: 0, gathering: true))
                fallback.emit = { [weak self, weak session] rows, payload in
                    guard let self, let session, self.sessions[key] === session, !self.index.ready else { return }
                    var result = payload; result["source"] = "spotlight"; result["indexing"] = true; result["query"] = session.text
                    session.update(result)
                }
                fallback.expired = { [weak self, weak session] in
                    guard let self, let session, self.sessions[key] === session else { return }
                    session.fallback = nil
                    if key.hasPrefix("native.files:") || Date().timeIntervalSince(session.touched) < 120 { self.run(session, key: key) }
                    else { self.cancel(key) }
                }
                fallback.schedule()
            } catch {
                var payload = session.payload([], total: 0, elapsed: 0, gathering: false)
                payload["error"] = error.localizedDescription; session.update(payload)
            }
        }
    }

    func handle(_ fn: String, args: [Any], pluginID: String = "native.files", reply: @escaping (Any?, String?) -> Void) {
        if fn == "search" {
            var pendingReply: ((Any?, String?) -> Void)? = reply
            search(args.first as? String ?? "", options: args.count > 1 ? args[1] as? [String: Any] ?? [:] : [:], pluginID: pluginID) { payload in
                if let pending = pendingReply { pendingReply = nil; pending(payload, nil) }
                else { PluginEvents.emit("files", payload, to: pluginID) }
            }
            let options = args.count > 1 ? args[1] as? [String: Any] ?? [:] : [:]
            let client = String((options["clientID"] as? String ?? "default").prefix(100))
            if let session = sessions[pluginID + ":" + client] {
                session.onCancel = { [weak session] in
                    guard let pending = pendingReply else { return }
                    pendingReply = nil
                    if let session {
                        var payload = session.payload([], total: 0, elapsed: 0, gathering: false)
                        payload["cancelled"] = true; pending(payload, nil)
                    } else { pending(nil, "Search was cancelled.") }
                }
            }
            return
        }
        if fn == "cancel" { cancel(pluginID + ":" + (args.first as? String ?? "default")); reply(NSNull(), nil); return }
        if fn == "keepAlive" {
            let session = sessions[pluginID + ":" + (args.first as? String ?? "default")]
            session?.touched = Date(); _ = session?.fallback?.touch(); reply(session != nil, nil); return
        }
        if fn == "status" {
            let status = index.status
            reply(["ready": index.ready, "count": status.count, "notice": status.diagnostic ?? ""], nil); return
        }
        if fn == "rebuild" { index.start(defaults: defaults, force: true); reply(NSNull(), nil); return }
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
            case "copyName":
                NSPasteboard.general.clearContents()
                guard NSPasteboard.general.setString(url.lastPathComponent, forType: .string) else { throw FileSearchError.message("Couldn't copy the name.") }
                reply(NSNull(), nil)
            case "trash":
                guard args.count > 1, (args[1] as? [String: Any])?["confirm"] as? Bool == true else { throw FileSearchError.message("Confirm moving this file to Trash.") }
                let canonical = FileIndexPath.canonical(url.path)
                guard canonical != "/", !FileNameIndex.Configuration(defaults: defaults).roots.contains(canonical) else { throw FileSearchError.message("Choose a file or subfolder inside an indexed folder.") }
                // Work off main; Trash may involve a mounted or cloud-backed volume.
                let index = index
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                        index.removed(url.path)
                        DispatchQueue.main.async { reply(NSNull(), nil) }
                    } catch { DispatchQueue.main.async { reply(nil, error.localizedDescription) } }
                }
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
        index.recordUse(path)
        NSDocumentController.shared.noteNewRecentDocumentURL(URL(fileURLWithPath: path))
    }
}

private final class FileIndexClient {
    let index: FileNameIndex
    let text, scope, kind, client, request: String
    let limit: Int
    let update: ([String: Any]) -> Void
    var touched = Date()
    var version = 0
    var fallback: FileSpotlightFallback?
    var onCancel: (() -> Void)?
    init(index: FileNameIndex, text: String, scope: String, kind: String, limit: Int, client: String, request: String, update: @escaping ([String: Any]) -> Void) {
        self.index = index
        self.text = text; self.scope = scope; self.kind = kind; self.limit = limit; self.client = client; self.request = request; self.update = update
    }
    func payload(_ results: [FileSearchResult], total: Int, elapsed: Double, gathering: Bool) -> [String: Any] {
        let status = index.status
        return ["clientID": client, "requestID": request, "query": text, "scope": scope, "kind": kind,
                "results": results.map(\.json), "gathering": gathering, "indexing": !index.ready,
                "truncated": total > results.count, "total": total, "elapsedMs": elapsed,
                "source": "index", "notice": status.diagnostic ?? ""]
    }
    deinit { fallback?.cancel() }
}
