import Foundation

/// All folder reads below target generated /tmp fixtures, never the real protected folders.
enum FileAccessTests {
    static func wait(_ label: String, _ condition: () -> Bool) {
        let deadline = Date(timeIntervalSinceNow: 8)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01)) }
        precondition(condition(), "Timed out: \(label)")
    }
    static func results(_ index: FileNameIndex) -> [FileSearchResult] {
        var rows: [FileSearchResult]?
        index.search("", scope: "all", client: "access-tests") { result in
            rows = (try? result.get().0) ?? []
        }
        wait("in-memory query") { rows != nil }
        return rows!
    }
    static func run() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "/private/tmp/nook-access-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) } // generated fixtures only
        let domain = "nook.files.access-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let folders = ["Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music", "Library/Mobile Documents", "Developer", "RemoteMount"]
        for folder in folders {
            let url = root.appendingPathComponent(folder, isDirectory: true)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: url.appendingPathComponent("access-marker.txt", isDirectory: false))
        }
        let policy = FileSearchAccessPolicy(home: root.path, volumes: [root.path + "/RemoteMount"])
        for folder in folders where folder != "Developer" {
            precondition(!policy.allows(root.path + "/" + folder + "/access-marker.txt"))
        }
        precondition(policy.allows(root.path + "/Documents-old/file.txt"))
        let realHome = FileSearchAccessPolicy(home: "/Users/access-test")
        precondition(!realHome.allows("/System/Volumes/Data/Users/access-test/Documents/file.txt"), "Data-volume aliases must use the same gate")
        precondition(!FileSearchAccessPolicy(home: root.path, granted: [root.path + "/Library"]).allows(root.path + "/Library/Mobile Documents/file.txt"), "Only explicitly requested standard folders can be remembered")
        precondition(!policy.allows(root.path + "/Developer/../Documents/file.txt"))
        precondition(!policy.allows("/Volumes/Example/file.txt") && !policy.allows("/Network/Example/file.txt"))
        let opted = FileSearchAccessPolicy(home: root.path, granted: [root.path + "/Desktop"])
        precondition(opted.allows(root.path + "/Desktop/file.txt") && !opted.allows(root.path + "/Documents/file.txt"))
        precondition(opted.needsAccess)
        precondition(FileSearchAccessPolicy(home: root.path, fullDiskAccess: true).allows(root.path + "/Library/Mobile Documents/file.txt"))
        // A stored opt-in alone is never mistaken for a successful grant.
        defaults.set(true, forKey: FileSearchAccessPolicy.requestedKey)
        precondition(!FileSearchAccessPolicy.current(defaults: defaults, home: root.path).allows(root.path + "/Downloads/file.txt"))
        defaults.set(true, forKey: "files.indexLibrary")
        defaults.set(root.path + "/Documents", forKey: "files.indexRoots")
        let alias = root.appendingPathComponent("DesktopAlias", isDirectory: true)
        try fm.createSymbolicLink(at: alias, withDestinationURL: root.appendingPathComponent("Desktop", isDirectory: true))
        precondition(policy.safeRoot(alias.path) == nil, "root aliases must not resolve into protected folders")
        let blocked = FileNameIndex.Configuration(defaults: defaults, home: root.path, access: policy)
        precondition(!blocked.accepts(root.path + "/Library/Mobile Documents/access-marker.txt"), "Include Library cannot bypass access gating")
        precondition(blocked.acceptsMetadata(root.path + "/Desktop/access-marker.txt"), "metadata may be used without reading a protected folder")
        let raw = nf_create()!
        blocked.scan(raw, root: root.path)
        let query = try FileIndexQuery("access-marker").compiled(scope: "", kind: "all")
        var hits = [NFHit](repeating: NFHit(), count: 20), total = 0
        precondition(nf_search(raw, query, nil, &hits, hits.count, &total) == 1, "scanner must exclude protected folders before accessing them")
        nf_query_destroy(query); nf_destroy(raw)

        // An actually blocked configuration/disk worker cannot block main or the
        // query queue. This would deadlock if configuration moved back to main.
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let cache = root.appendingPathComponent(".index", isDirectory: true)
        let index = FileNameIndex(cacheDirectory: cache, home: root.path, configure: { _, _, _ in
            precondition(!Thread.isMainThread)
            entered.signal(); precondition(release.wait(timeout: .now() + 5) == .success, "configuration must not block the calling thread")
            return blocked
        })
        index.start(defaults: defaults)
        precondition(entered.wait(timeout: .now() + 2) == .success)
        precondition(results(index).isEmpty && !index.ready, "search remains responsive during a blocked disk walk")
        release.signal(); wait("gated build") { index.ready }
        precondition(!results(index).contains { $0.path.contains("/Desktop/") || $0.path.contains("/Documents/") || $0.path.contains("/Downloads/") })
        let bridge = FileSearchService(defaults: defaults, index: index)
        var preview: [String: Any]?
        bridge.handle("preview", args: [root.path + "/Documents/missing.txt"]) { value, failure in
            precondition(failure == nil); preview = value as? [String: Any]
        }
        precondition(preview?["notice"] != nil, "automatic preview must stop before fileURL/existence/thumbnail reads")
        var aliasPreview: [String: Any]?
        bridge.handle("preview", args: [alias.path]) { value, failure in
            precondition(failure == nil); aliasPreview = value as? [String: Any]
        }
        wait("safe symlink preview") { aliasPreview != nil }
        precondition(aliasPreview?["notice"] != nil, "automatic previews must not follow aliases into protected locations")
        index.shutdown()

        // A deliberately missing Documents folder cannot be persisted as granted.
        try fm.removeItem(at: root.appendingPathComponent("Documents", isDirectory: true))
        let access = FileSearchAccess(defaults: defaults, home: root.path)
        access.allow(); wait("explicit consent") { !access.requesting }
        let remembered = defaults.stringArray(forKey: FileSearchAccessPolicy.grantedKey) ?? []
        precondition(remembered.contains(root.path + "/Desktop") && remembered.contains(root.path + "/Downloads"))
        precondition(!remembered.contains(root.path + "/Documents"))
        let after = FileSearchAccessPolicy.current(defaults: defaults, home: root.path)
        precondition(after.allows(root.path + "/Desktop/access-marker.txt"), "successful opt-in survives a fresh policy")
        let granted = FileNameIndex.Configuration(defaults: defaults, home: root.path, access: after)
        precondition(granted.hash != blocked.hash, "access changes must invalidate previously saved catalogs")
        let restored = FileNameIndex(cacheDirectory: cache, home: root.path)
        restored.start(defaults: defaults); wait("opt-in rebuild") { restored.ready }
        precondition(!restored.status.restored && results(restored).contains { $0.path.contains("/Downloads/") })
        restored.shutdown()
        access.revoke()
        precondition(!FileSearchAccessPolicy.current(defaults: defaults, home: root.path).allows(root.path + "/Desktop/file.txt"))
        let revoked = FileNameIndex(cacheDirectory: cache, home: root.path)
        revoked.start(defaults: defaults); wait("revoked rebuild") { revoked.ready }
        precondition(!revoked.status.restored && !results(revoked).contains { $0.path.contains("/Desktop/") || $0.path.contains("/Downloads/") })
        revoked.shutdown()
        print("PASS: protected/cloud/mount gates, lexical boundaries and symlink roots, scanner exclusions, nonblocking startup/query, safe previews, explicit-only successful grants, remembered choice and cache invalidation/revocation")
    }
}
