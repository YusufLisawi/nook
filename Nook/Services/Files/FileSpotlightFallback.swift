import Foundation

/// Metadata-only fallback and protected-folder overlay. Never opens result URLs.
final class FileSpotlightFallback {
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
    var candidatePredicate: NSPredicate?
    var allowsPath: ((String) -> Bool)?
    var rankResults: (([FileSearchResult]) -> [FileSearchResult])?

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
        query.predicate = candidatePredicate ?? FileSearchPolicy.predicate(query: queryText, kind: kind)
        // This symbolic scope preflights access without requesting it. Folder
        // URL/string scopes perform filesystem checks and can display TCC prompts.
        query.searchScopes = [NSMetadataQueryUserHomeScope]
        query.notificationBatchingInterval = 0.025
        query.sortDescriptors = queryText.isEmpty ? [NSSortDescriptor(key: "kMDItemDateAdded", ascending: false), NSSortDescriptor(key: "kMDItemFSContentChangeDate", ascending: false)] : []
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
        rankResults?(results) ?? FileSearchPolicy.ranked(results, query: queryText, preferences: preferences, usage: usage)
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
        let allowsPath = allowsPath
        // Metadata can require IPC or disk access. Keep the frozen query on main, and read
        // only its independent item references here so typing and cancellation stay responsive.
        Self.metadataWorker.async { [weak self] in
            let results = items.compactMap { item -> FileSearchResult? in
                guard let path = item.value(forAttribute: "kMDItemPath") as? String, preferences.allows(path), allowsPath?(path) ?? true else { return nil }
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
