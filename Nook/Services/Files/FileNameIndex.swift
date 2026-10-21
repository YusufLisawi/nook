import Foundation
import CoreServices
import UniformTypeIdentifiers
import Darwin

/// Owns the packed C index. Disk traversal and persistence never run on the main thread.
/// Searches share a short lock with in-memory merges; all filesystem reads happen outside it.
final class FileNameIndex {
    private final class StreamContext {
        weak var index: FileNameIndex?
        init(_ index: FileNameIndex) { self.index = index }
    }
    static let shared = FileNameIndex()
    static let changed = Notification.Name("nookFileIndexChanged")
    private let lock = NSLock()
    private let updates = DispatchQueue(label: "com.yusuf.nook.files.index", qos: .utility)
    private let queries = DispatchQueue(label: "com.yusuf.nook.files.search", qos: .userInitiated)
    private var store: OpaquePointer?
    private var cursors: [String: OpaquePointer] = [:] // query queue only
    private var stream: FSEventStreamRef?
    private var saveWork: DispatchWorkItem?
    private var eventID: UInt64 = 0
    private var fingerprint: UInt64 = 0
    private var config: Configuration?
    private var _ready = false
    private var _diagnostic: String?
    private var _count = 0
    private var _restored = false
    private var started = false
    private var rebuildVersion = 0
    private var forcePending = false
    private let cacheDirectory: URL
    private let home: String

    struct Configuration: Equatable {
        let roots: [String]
        let homeRoot: String
        let excluded: String
        let hidden, library, dependencies, packages: Bool
        init(defaults: UserDefaults = .standard, home: String = NSHomeDirectory(), cachePath: String? = nil) {
            let additional = (defaults.string(forKey: "files.indexRoots") ?? "").components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("/") || $0.hasPrefix("~/") }
                .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL.path }.filter { $0 != "/" }
            let physicalRoots: [String] = ([home] + additional).map { FileIndexPath.canonical($0) }
            let candidates: [String] = Set(physicalRoots).sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count < rhs.count }
                return lhs < rhs
            }
            var unique: [String] = []
            for path in candidates where !unique.contains(where: { FileSearchPolicy.isInside(path, root: $0) }) { unique.append(path) }
            roots = unique
            homeRoot = FileIndexPath.canonical(home)
            let snapshot = FileSearchPreferences.Snapshot(defaults: defaults)
            hidden = snapshot.showHidden; library = defaults.bool(forKey: "files.indexLibrary")
            dependencies = defaults.bool(forKey: "files.indexDependencies"); packages = defaults.bool(forKey: "files.indexPackages")
            excluded = (snapshot.excluded + [cachePath ?? home + "/Library/Caches/com.yusuf.nook/FileIndex"] + (library ? [] : [home + "/Library"]))
                .map(FileIndexPath.canonical).joined(separator: "\n")
        }
        var hash: UInt64 {
            let journals = roots.map { root -> String in
                var info = stat()
                guard stat(root, &info) == 0, let uuid = FSEventsCopyUUIDForDevice(info.st_dev) else { return "" }
                return CFUUIDCreateString(nil, uuid) as String
            }
            let text = roots.joined(separator: "\n") + journals.joined(separator: "|") + "|" + excluded + "|\(hidden)|\(library)|\(dependencies)|\(packages)|v2"
            return text.utf8.reduce(0xcbf29ce484222325) { ($0 ^ UInt64($1)) &* 0x100000001b3 }
        }
        func scan(_ index: OpaquePointer, root: String) {
            nf_scan(index, root, excluded, hidden ? 1 : 0, library ? 1 : 0, dependencies ? 1 : 0, packages ? 1 : 0)
        }
        func accepts(_ path: String) -> Bool {
            guard roots.contains(where: { FileSearchPolicy.isInside(path, root: $0) }) else { return false }
            if excluded.components(separatedBy: .newlines).contains(where: { !$0.isEmpty && FileSearchPolicy.isInside(path, root: $0) }) { return false }
            let components = path.split(separator: "/").map(String.init)
            if components.contains(where: { [".Trash", ".Trashes", ".Spotlight-V100", ".fseventsd", ".DocumentRevisions-V100", ".TemporaryItems"].contains($0) }) { return false }
            if !hidden && components.contains(where: { $0.hasPrefix(".") }) { return false }
            if !library && FileSearchPolicy.isInside(path, root: homeRoot + "/Library") { return false }
            if !dependencies && components.contains(where: { Self.dependencyNames.contains($0) }) { return false }
            if !packages && components.dropLast().contains(where: { Self.packageExtensions.contains(($0 as NSString).pathExtension.lowercased()) }) { return false }
            return true
        }
        static let dependencyNames = Set("node_modules .git DerivedData build .build dist .next .nuxt Pods venv .venv site-packages __pycache__ .cache Caches .npm .pnpm-store .yarn .gradle .cargo .rustup .swiftpm".split(separator: " ").map(String.init))
        static let packageExtensions = Set("app bundle framework plugin appex photoslibrary photolibrary xcassets xcodeproj xcworkspace playground pages numbers key rtfd sparsebundle band logicx garageband".split(separator: " ").map(String.init))
    }

    init(cacheDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/com.yusuf.nook/FileIndex"), home: String = NSHomeDirectory()) {
        self.cacheDirectory = URL(fileURLWithPath: FileIndexPath.canonical(cacheDirectory.path)); self.home = FileIndexPath.canonical(home)
    }
    deinit {
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
        for cursor in cursors.values { nf_cursor_destroy(cursor) }
        nf_destroy(store)
    }
    var ready: Bool { lock.lock(); defer { lock.unlock() }; return _ready }
    var status: (count: Int, diagnostic: String?, restored: Bool) { lock.lock(); defer { lock.unlock() }; return (_count, _diagnostic, _restored) }

    func start(defaults: UserDefaults = .standard, force: Bool = false) {
        let next = Configuration(defaults: defaults, home: home, cachePath: cacheDirectory.path)
        lock.lock(); rebuildVersion += 1; let revision = rebuildVersion; forcePending = forcePending || force; lock.unlock()
        updates.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let current = self.rebuildVersion == revision, requestedForce = self.forcePending
            if current { self.forcePending = false }
            self.lock.unlock()
            guard current, requestedForce || !self.started || self.config != next else { return }
            self.started = true; self.config = next; self.fingerprint = next.hash
            self.stopWatching(); self.saveWork?.cancel(); self.saveWork = nil
            self.lock.lock(); self._ready = false; self.lock.unlock()
            self.publish()
            self.build(next, force: requestedForce)
        }
    }

    private var cacheURL: URL { cacheDirectory.appendingPathComponent("names.bin") }
    private func build(_ config: Configuration, force: Bool) {
        fingerprint = config.hash
        let baseline = FSEventsGetCurrentEventId()
        var saved: UInt64 = 0
        var loaded = force ? nil : nf_load(cacheURL.path, config.hash, &saved)
        if loaded != nil && saved > baseline { nf_destroy(loaded); loaded = nil }
        let index = loaded ?? nf_create()!
        if loaded == nil {
            for root in config.roots { config.scan(index, root: root) }
        }
        lock.lock()
        let old = store; store = index; _ready = true; _count = Int(nf_count(index))
        _restored = loaded != nil
        let skipped = nf_skipped(index)
        _diagnostic = skipped > 0 ? "\(skipped) locations couldn't be read. Check Files & Folders permissions." : nil
        lock.unlock(); nf_destroy(old)
        // Capture the baseline BEFORE scanning. Replay all changes made during a first scan.
        // A cached catalog replays from its last successfully persisted event watermark.
        eventID = loaded != nil ? saved : baseline
        startWatching(config.roots, since: eventID)
        persistSoon(); publish()
    }

    private func startWatching(_ roots: [String], since: UInt64) {
        #if FILE_INDEX_DIAGNOSTICS
        fputs("WATCH \(roots) since=\(since)\n", stderr)
        #endif
        let box = StreamContext(self)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(box).toOpaque(), retain: { info in
            guard let info else { return nil }
            _ = Unmanaged<StreamContext>.fromOpaque(info).retain(); return info
        }, release: { info in
            if let info { Unmanaged<StreamContext>.fromOpaque(info).release() }
        }, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, ids in
            guard let info else { return }
            guard let index = Unmanaged<StreamContext>.fromOpaque(info).takeUnretainedValue().index else { return }
            let names = unsafeBitCast(paths, to: NSArray.self)
            var changes: [(String, UInt32, UInt64)] = []
            for i in 0..<count { if let path = names[i] as? String { changes.append((path, flags[i], ids[i])) } }
            index.receive(changes)
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(nil, callback, &context, roots as CFArray, since, 0.15, flags) else {
            setDiagnostic("Live updates unavailable. Rebuild the index in File Search Settings."); return
        }
        FSEventStreamSetDispatchQueue(stream, updates)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
            setDiagnostic("Live updates unavailable. Rebuild the index in File Search Settings."); return
        }
        self.stream = stream
    }
    private func stopWatching() {
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
        stream = nil
    }
    private func receive(_ events: [(String, UInt32, UInt64)]) {
        #if FILE_INDEX_DIAGNOSTICS
        fputs("EVENTS \(events)\n", stderr)
        #endif
        guard let config else { return }
        let lost = UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagRootChanged)
        if events.contains(where: { $0.1 & lost != 0 }) {
            lock.lock(); _ready = false; lock.unlock(); publish()
            stopWatching(); build(config, force: true); return
        }
        var paths: [String: UInt32] = [:]
        for (raw, flags, id) in events {
            eventID = max(eventID, id)
            if flags & UInt32(kFSEventStreamEventFlagHistoryDone) != 0 { continue }
            let path = raw.hasPrefix("/System/Volumes/Data/") ? String(raw.dropFirst("/System/Volumes/Data".count)) : raw
            // Default Library exclusion also keeps our cache writes out of the update loop.
            if FileSearchPolicy.isInside(path, root: cacheDirectory.path) { continue }
            guard config.accepts(path) else {
                #if FILE_INDEX_DIAGNOSTICS
                fputs("EXCLUDED \(path) roots=\(config.roots)\n", stderr)
                #endif
                continue
            }
            paths[path, default: 0] |= flags
        }
        for (path, flags) in paths {
            // A directory rename/create needs its descendants; ordinary directory metadata
            // changes only refresh the directory itself. lstat checks happen in the C scanner.
            let recursive = flags & UInt32(kFSEventStreamEventFlagItemIsDir) != 0 && flags & UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemFinderInfoMod | kFSEventStreamEventFlagItemInodeMetaMod) != 0
            reconcile(path, recursive: recursive, config: config)
        }
        if !paths.isEmpty { publish() }
        if !paths.isEmpty || events.contains(where: { $0.1 & UInt32(kFSEventStreamEventFlagHistoryDone) != 0 }) { persistSoon() }
    }

    private func reconcile(_ path: String, recursive: Bool, config: Configuration) {
        let fresh = nf_create()!
        // Non-recursive updates use a single lstat/resource lookup; avoid recrawling a
        // large parent each time a child's modification updates that parent's timestamp.
        if recursive { config.scan(fresh, root: path) }
        else if let record = Self.readRecord(path, config: config) { Self.put(record, into: fresh) }
        #if FILE_INDEX_DIAGNOSTICS
        fputs("RECONCILE \(path) recursive=\(recursive) fresh=\(nf_count(fresh))\n", stderr)
        #endif
        lock.lock()
        if let store {
            nf_remove(store, path, recursive ? 1 : 0); nf_merge(store, fresh); _count = Int(nf_count(store))
        }
        lock.unlock(); nf_destroy(fresh)
    }

    private static func readRecord(_ path: String, config: Configuration) -> FileSearchResult? {
        let url = URL(fileURLWithPath: path)
        guard !config.excluded.components(separatedBy: .newlines).contains(where: { !$0.isEmpty && FileSearchPolicy.isInside(path, root: $0) }) else { return nil }
        if !config.hidden && path.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { return nil }
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isHiddenKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey, .addedToDirectoryDateKey, .contentTypeKey]) else { return nil }
        if !config.hidden && values.isHidden == true { return nil }
        if !config.packages {
            var parent = url.deletingLastPathComponent()
            while config.roots.contains(where: { FileSearchPolicy.isInside(parent.path, root: $0) }) {
                if (try? parent.resourceValues(forKeys: [.isPackageKey]).isPackage) == true { return nil }
                let next = parent.deletingLastPathComponent(); if next == parent { break }; parent = next
            }
        }
        let type = values.contentType ?? UTType(filenameExtension: url.pathExtension)
        var types = type.map { [$0.identifier] } ?? []
        if values.isDirectory == true && values.isSymbolicLink != true { types.append(url.pathExtension.lowercased() == "app" ? "com.apple.application-bundle" : "public.folder") }
        else if type?.conforms(to: .image) == true { types.append("public.image") }
        else if type?.conforms(to: .movie) == true { types.append("public.movie") }
        else if type?.conforms(to: .audio) == true { types.append("public.audio") }
        else if type?.conforms(to: .archive) == true { types.append("public.archive") }
        return FileSearchResult(path: path, name: url.lastPathComponent, kind: "File", size: Int64(values.fileSize ?? 0),
                                modified: values.contentModificationDate?.timeIntervalSince1970 ?? 0, lastUsed: 0, contentTypes: types,
                                hidden: values.isHidden == true, added: (values.addedToDirectoryDate ?? values.creationDate)?.timeIntervalSince1970 ?? 0)
    }
    private static func put(_ item: FileSearchResult, into index: OpaquePointer) {
        item.path.withCString { path in
            item.name.withCString { name in
                let kind = ["document", "folder", "app", "image", "pdf", "code", "video", "audio", "archive"].firstIndex(of: item.category) ?? 0
                var record = NFRecord(path: path, name: name, size: item.size, modified: item.modified, added: item.added, opened: item.lastUsed, uses: 0, kind: UInt8(kind), hidden: item.hidden ? 1 : 0)
                nf_put(index, &record)
            }
        }
    }
    /// Apply the same grammar to bounded Spotlight candidates during the first build.
    /// This avoids displaying false-positive extension/kind/exclusion matches in fallback.
    static func rankCandidates(_ candidates: [FileSearchResult], query: FileIndexQuery, kind: String) -> [FileSearchResult] {
        let temporary = nf_create()!; defer { nf_destroy(temporary) }
        var byPath: [String: FileSearchResult] = [:]
        for candidate in candidates { put(candidate, into: temporary); byPath[candidate.path] = candidate }
        let compiled = query.compiled(scope: "", kind: kind); defer { nf_query_destroy(compiled) }
        var hits = [NFHit](repeating: NFHit(), count: 500), total = 0
        let count = nf_search(temporary, compiled, nil, &hits, hits.count, &total)
        return hits.prefix(count).compactMap { hit in
            var record = NFRecord()
            guard nf_record(temporary, hit.id, &record) != 0 else { return nil }
            return byPath[String(cString: record.path)]
        }
    }
    private func persistSoon() {
        // Throttle, don't debounce: active development can generate events indefinitely.
        guard saveWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }; self.saveWork = nil
            self.compactIfNeeded()
            do {
                try FileManager.default.createDirectory(at: self.cacheDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let saved = self.store.map { nf_save($0, self.cacheURL.path, self.eventID, self.fingerprint) != 0 } ?? false
                if !saved { self.setDiagnostic("Couldn't save the file index. Check available disk space.") }
            } catch { self.setDiagnostic("Couldn't save the file index: \(error.localizedDescription)") }
        }
        saveWork = work; updates.asyncAfter(deadline: .now() + 5, execute: work)
    }
    private func compactIfNeeded() {
        guard let current = store else { return }
        let live = nf_count(current)
        guard nf_slots(current) > live + max(10_000, live / 4) else { return }
        let compacted = nf_create()!
        nf_merge(compacted, current) // read-only; queries can continue through this copy
        lock.lock(); store = compacted; lock.unlock()
        nf_destroy(current)
    }
    /// Normal-quit flush; tests also use this to exercise an actual restart catch-up.
    func shutdown() {
        updates.sync {
            stopWatching(); saveWork?.cancel(); saveWork = nil
            if let store {
                try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                _ = nf_save(store, cacheURL.path, eventID, fingerprint)
            }
        }
    }
    private func setDiagnostic(_ message: String) { lock.lock(); _diagnostic = message; lock.unlock(); publish() }
    private func publish() { DispatchQueue.main.async { NotificationCenter.default.post(name: Self.changed, object: self) } }

    func search(_ text: String, scope: String = "home", kind: String = "all", limit: Int = 60, client: String = "native", reply: @escaping (Result<([FileSearchResult], Int, Double), Error>) -> Void) {
        queries.async { [weak self] in
            guard let self else { return }
            let start = CFAbsoluteTimeGetCurrent()
            do {
                let parsed = try FileIndexQuery(text)
                let root = scope == "all" ? "" : scope == "home" ? self.home : self.home + "/" + scope
                let query = parsed.compiled(scope: root, kind: kind); defer { nf_query_destroy(query) }
                if self.cursors[client] == nil {
                    if self.cursors.count >= 24, let key = self.cursors.keys.first { nf_cursor_destroy(self.cursors.removeValue(forKey: key)) }
                    self.cursors[client] = nf_cursor_create()
                }
                var hits = [NFHit](repeating: NFHit(), count: min(100, max(1, limit))), total = 0
                self.lock.lock()
                let count = nf_search(self._ready ? self.store : nil, query, self.cursors[client], &hits, hits.count, &total)
                var results: [FileSearchResult] = []
                let types = [[], ["public.folder"], ["com.apple.application-bundle"], ["public.image"], ["com.adobe.pdf"], ["public.source-code"], ["public.movie"], ["public.audio"], ["public.archive"]]
                let labels = ["Document", "Folder", "Application", "Image", "PDF", "Code", "Video", "Audio", "Archive"]
                for hit in hits.prefix(count) {
                    var record = NFRecord()
                    if nf_record(self.store, hit.id, &record) != 0 {
                        results.append(FileSearchResult(path: String(cString: record.path), name: String(cString: record.name), kind: labels[Int(record.kind)], size: record.size, modified: record.modified, lastUsed: record.opened, contentTypes: types[Int(record.kind)], hidden: record.hidden != 0, added: record.added))
                    }
                }
                self.lock.unlock()
                let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
                DispatchQueue.main.async { reply(.success((results, total, elapsed))) }
            } catch { DispatchQueue.main.async { reply(.failure(error)) } }
        }
    }
    func recordUse(_ path: String) {
        updates.async { [weak self] in
            guard let self else { return }
            let canonical = FileIndexPath.file(path)
            self.lock.lock(); if let store = self.store { nf_use(store, canonical, Date().timeIntervalSince1970) }; self.lock.unlock()
            self.persistSoon(); self.publish()
        }
    }
    func cancel(client: String) {
        queries.async { [weak self] in
            if let cursor = self?.cursors.removeValue(forKey: client) { nf_cursor_destroy(cursor) }
        }
    }
    func removed(_ path: String) {
        updates.async { [weak self] in
            guard let self else { return }
            let canonical = FileIndexPath.file(path)
            self.lock.lock(); if let store = self.store { nf_remove(store, canonical, 1); self._count = Int(nf_count(store)) }; self.lock.unlock()
            self.persistSoon(); self.publish()
        }
    }
}
