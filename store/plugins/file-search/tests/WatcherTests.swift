import Foundation

@main
struct WatcherTests {
    static func wait(_ description: String, timeout: Double = 8, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.025)) }
        precondition(condition(), "Timed out: \(description)")
    }
    static func results(_ index: FileNameIndex, _ text: String = "") -> [FileSearchResult] {
        var rows: [FileSearchResult]?, failure: Error?
        index.search(text, scope: "all", client: "watcher-test") { result in
            switch result { case .success(let (value, _, _)): rows = value; case .failure(let error): failure = error; rows = [] }
        }
        wait("query completes") { rows != nil }
        precondition(failure == nil); return rows ?? []
    }
    static func eventually(_ index: FileNameIndex, _ name: String, exists: Bool) {
        let deadline = Date().addingTimeInterval(8)
        var matched = false
        repeat {
            let found = results(index, name).contains { $0.name == name }
            if found == exists { matched = true; break }
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        precondition(matched, "event update: \(name) expected exists=\(exists)")
    }
    static func main() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "/tmp").resolvingSymlinksInPath().appendingPathComponent("nook-file-watch-\(UUID().uuidString)")
        let cache = root.appendingPathComponent(".cache")
        try fm.createDirectory(at: root.appendingPathComponent("Downloads/Folder"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) } // This process's own generated fixtures only.
        let domain = "nook.file-watch-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let initial = root.appendingPathComponent("Downloads/initial.txt")
        try Data("first".utf8).write(to: initial)
        let child = root.appendingPathComponent("Downloads/Folder/child.txt")
        try Data("child".utf8).write(to: child)
        defaults.set(true, forKey: FileSearchAccessPolicy.requestedKey)
        defaults.set([root.appendingPathComponent("Downloads").path], forKey: FileSearchAccessPolicy.grantedKey)
        let index = FileNameIndex(cacheDirectory: cache, home: root.path)
        index.start(defaults: defaults)
        wait("initial build") { index.ready }
        precondition(!index.status.restored && results(index, "initial.txt").count == 1)
        let new = root.appendingPathComponent("Downloads/added-new.txt")
        try Data("new".utf8).write(to: new)
        eventually(index, "added-new.txt", exists: true)
        precondition(results(index).first?.name == "added-new.txt", "Recent puts a newly added, never-opened file first")
        try Data("changed content".utf8).write(to: new, options: .atomic)
        wait("size updated") { results(index, "added-new.txt").first?.size == 15 }
        try fm.moveItem(at: root.appendingPathComponent("Downloads/Folder"), to: root.appendingPathComponent("Downloads/Moved"))
        wait("subtree renamed") { results(index, "child.txt").first?.path.contains("/Moved/") == true }
        try fm.removeItem(at: root.appendingPathComponent("Downloads/Moved"))
        eventually(index, "child.txt", exists: false)
        // Build folders created after launch remain excluded too.
        try fm.createDirectory(at: root.appendingPathComponent("Downloads/build"), withIntermediateDirectories: true)
        try Data("excluded".utf8).write(to: root.appendingPathComponent("Downloads/build/skip-marker.txt"))
        _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.5))
        precondition(results(index, "skip-marker").isEmpty)
        index.shutdown()
        let after = root.appendingPathComponent("Downloads/while-stopped.txt")
        try Data("catch up".utf8).write(to: after)
        try fm.removeItem(at: initial)
        let restored = FileNameIndex(cacheDirectory: cache, home: root.path)
        restored.start(defaults: defaults)
        wait("cache restore") { restored.ready }
        precondition(restored.status.restored, "restart must load the saved binary catalog")
        eventually(restored, "while-stopped.txt", exists: true)
        eventually(restored, "initial.txt", exists: false)
        restored.shutdown()
        restored.stop()
        precondition(!restored.ready && restored.status.count == 0 && restored.configuration == nil, "off releases all packed index state")
        restored.stop()
        restored.start(defaults: defaults)
        wait("re-enable after teardown") { restored.ready }
        eventually(restored, "while-stopped.txt", exists: true)
        restored.stop()
        print("PASS: real FSEvents creation, modified size, directory rename/removal, post-launch exclusions, binary-cache restart and sinceWhen catch-up, using only /tmp fixtures")
    }
}
