import Foundation
import Darwin

/// Run with its own launchd identity (permission-probe.sh), not a terminal's FDA.
/// Does not launch Nook, display a window, or read any file contents.
@main
struct PermissionProbe {
    static func main() throws {
        let home = NSHomeDirectory()
        print("pid=\(getpid()) FDA sentinel readable=\(FileSearchAccessPolicy.hasFullDiskAccess())")
        fflush(stdout)
        let query = NSMetadataQuery()
        // Explicit folder scopes are deliberately not available here: they were
        // observed to request Desktop TCC access in the first standalone probe.
        query.searchScopes = [NSMetadataQueryUserHomeScope]
        query.predicate = NSPredicate(format: "kMDItemFSContentChangeDate > %@", Date(timeIntervalSinceNow: -7 * 86400) as NSDate)
        var done = false
        let token = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main) { _ in done = true }
        precondition(query.start())
        let deadline = Date(timeIntervalSinceNow: 15)
        while !done && Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.025)) }
        var counts: [String: Int] = [:]
        var rows = 0
        for index in 0..<query.resultCount {
            guard let item = query.result(at: index) as? NSMetadataItem, let value = FileSearchResult(item: item) else { continue }
            _ = value.category // catches accidental URL stat in presentation logic
            rows += 1
            for folder in ["Desktop", "Documents", "Downloads", "Library/Mobile Documents"] where FileSearchPolicy.isInside(value.path, root: home + "/" + folder) { counts[folder, default: 0] += 1 }
        }
        query.stop(); NotificationCenter.default.removeObserver(token)
        print("symbolic home query finished=\(done) metadataRows=\(rows) protectedRows=\(counts)")
        fflush(stdout)
        guard CommandLine.arguments.count > 1 else { return }
        let cache = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        precondition(cache.path.hasPrefix("/private/tmp/") || cache.path.hasPrefix("/tmp/"))
        let domain = "nook.files.permission-probe.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let index = FileNameIndex(cacheDirectory: cache, home: home)
        let started = Date()
        index.start(defaults: defaults)
        print("index.start returnedMs=\(Date().timeIntervalSince(started) * 1000)")
        let buildDeadline = Date(timeIntervalSinceNow: 90)
        while !index.ready && Date() < buildDeadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.025)) }
        precondition(index.ready)
        print("gated home index ready names=\(index.status.count) buildMs=\(Date().timeIntervalSince(started) * 1000) needsAccess=\(index.configuration?.access.needsAccess == true)")
        for text in ["Nook", "readme", "swift", "report", ""] {
            var samples: [Double] = []
            for trial in 0..<7 {
                var completed = false
                index.search(text, scope: "all", client: "probe-\(trial)") { result in
                    if case .success(let (rows, _, ms)) = result {
                        precondition(rows.allSatisfy { index.configuration?.access.allows($0.path) == true })
                        samples.append(ms)
                    }
                    completed = true
                }
                while !completed { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.002)) }
            }
            print("query=\(text.isEmpty ? "<Recent>" : text) medianMs=\(samples.sorted()[samples.count / 2])")
        }
        index.shutdown()
        print("PASS: metadata-only query and gated home index finished without a folder scope or consent")
        fflush(stdout)
    }
}
