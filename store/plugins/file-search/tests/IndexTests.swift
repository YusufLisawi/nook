import Foundation
import Darwin

@main
struct IndexTests {
    static let now = 1_800_000_000.0
    static func put(_ index: OpaquePointer, _ path: String, added: Double = now, modified: Double = 0, size: Int64 = 20, kind: UInt8 = 0) {
        path.withCString { path in
            var record = NFRecord(path: path, name: path, size: size, modified: modified, added: added, opened: 0, uses: 0, kind: kind, hidden: 0)
            nf_put(index, &record)
        }
    }
    static func find(_ index: OpaquePointer, _ text: String, limit: Int = 100, cursor: OpaquePointer? = nil, scope: String = "", kind: String = "all") throws -> (rows: [NFRecord], total: Int) {
        let parsed = try FileIndexQuery(text, now: Date(timeIntervalSince1970: now))
        let query = parsed.compiled(scope: scope, kind: kind, now: Date(timeIntervalSince1970: now)); defer { nf_query_destroy(query) }
        var hits = [NFHit](repeating: NFHit(), count: limit), total = 0
        let count = nf_search(index, query, cursor, &hits, hits.count, &total)
        return (hits.prefix(count).map { hit in var record = NFRecord(); precondition(nf_record(index, hit.id, &record) != 0); return record }, total)
    }
    static func names(_ index: OpaquePointer, _ text: String, limit: Int = 100, cursor: OpaquePointer? = nil) throws -> [String] {
        try find(index, text, limit: limit, cursor: cursor).rows.map { String(cString: $0.name) }
    }
    static func main() throws {
        if CommandLine.arguments.contains("--benchmark") { try benchmark(); return }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let query = try FileIndexQuery("\"annual report\" !draft | ext:pdf;docx kind:image|folder", calendar: calendar)
        precondition(query.atoms.map(\.group) == [0, 0, 1, 1])
        precondition(query.atoms[1].type == 16 && query.atoms[2].text == "pdf;docx" && query.atoms[3].number == 10)
        let date = try FileIndexQuery("dm:2026-10-21 added:week size:>10mb", now: Date(timeIntervalSince1970: now), calendar: calendar)
        precondition(date.atoms.count == 4 && date.atoms[3].number == 10_485_760)
        for invalid in ["|foo", "foo|", "foo||bar", "!", "kind:unknown", "size:wat", "size:>nan", "dm:2026-02-30", "ext:", "\"oops"] {
            do { _ = try FileIndexQuery(invalid); preconditionFailure("accepted invalid \(invalid)") } catch { }
        }
        let index = nf_create()!; defer { nf_destroy(index) }
        put(index, "/NookIndexFixture/Downloads/report-old.pdf", added: now - 365 * 86400, kind: 4)
        put(index, "/NookIndexFixture/Downloads/report-new.pdf", added: now, kind: 4)
        put(index, "/NookIndexFixture/Downloads/report-modified.pdf", added: now - 365 * 86400, modified: now + 1, kind: 4)
        put(index, "/NookIndexFixture/Desktop/report.pdf", added: now - 86400, kind: 4)
        put(index, "/NookIndexFixture/Desktop/my report.pdf", added: now + 100, kind: 4)
        put(index, "/NookIndexFixture/Desktop/myreport.pdf", added: now + 100, kind: 4)
        put(index, "/NookIndexFixture/Desktop/résumé.swift", kind: 5)
        put(index, "/NookIndexFixture/Desktop/photo.png", size: 20_000_000, kind: 3)
        put(index, "/NookIndexFixture/Desktop/Project", kind: 1)
        let rankedNames = try names(index, "report")
        precondition(rankedNames == ["report.pdf", "report-modified.pdf", "report-new.pdf", "report-old.pdf", "my report.pdf", "myreport.pdf"], "name tier then added/modified recency: \(rankedNames)")
        precondition(tryValue { try names(index, "rpt") }.count == 6, "subsequence")
        precondition(tryValue { try names(index, "report !old") }.count == 5)
        precondition(tryValue { try names(index, "report new") } == ["report-new.pdf"])
        precondition(tryValue { try names(index, "report new | photo") }.count == 2, "AND before OR")
        precondition(tryValue { try names(index, "photo | resume") }.count == 2)
        precondition(tryValue { try names(index, "*.png size:>10mb") } == ["photo.png"])
        precondition(tryValue { try names(index, "kind:image|folder") }.count == 2)
        precondition(tryValue { try names(index, "folder:") } == ["Project"])
        precondition(tryValue { try names(index, "file: ext:pdf;swift") }.count == 7)
        precondition(tryValue { try find(index, "/NookIndexFixture/Desktop/ report").rows.count } == 3, "case-preserving path scope")
        precondition(tryValue { try find(index, "", scope: "/NookIndexFixture/Down").rows.isEmpty })
        precondition(tryValue { try names(index, "", limit: 1) } == ["my report.pdf"], "empty query includes never-opened new files")
        nf_use(index, "/NookIndexFixture/Downloads/report-old.pdf", now)
        precondition(tryValue { try names(index, "report") }[1] == "report-old.pdf", "Nook opened frecency within tier")
        precondition(tryValue { try FileIndexQuery("resume").highlights(in: "résumé.swift") } == Set(0..<6))
        precondition(tryValue { try FileIndexQuery("rpt").highlights(in: "report.pdf") } == Set([0, 2, 5]))
        let words = nf_create()!
        put(words, "/NookIndexFixture/FileSearch.swift", added: now - 100)
        put(words, "/NookIndexFixture/filesearch.swift", added: now)
        precondition(tryValue { try names(words, "search") }.first == "FileSearch.swift", "camel case word boundary dominates recency")
        put(words, "/NookIndexFixture/新.png", kind: 3)
        precondition(tryValue { try names(words, "?.png") } == ["新.png"], "wildcard is a Unicode scalar")
        nf_destroy(words)

        let cursor = nf_cursor_create()!; defer { nf_cursor_destroy(cursor) }
        _ = try find(index, "r", limit: 1, cursor: cursor)
        precondition(tryValue { try names(index, "resume", cursor: cursor) } == ["résumé.swift"], "narrowing retains matches beyond top K")
        put(index, "/NookIndexFixture/Desktop/resume-new.txt", added: now + 5)
        precondition(tryValue { try names(index, "resume", cursor: cursor) }.contains("resume-new.txt"), "updates invalidate narrowing")
        let first = nf_create()!, second = nf_create()!, isolatedCursor = nf_cursor_create()!
        put(first, "/NookIndexFixture/report.txt"); put(first, "/NookIndexFixture/invoice.txt")
        put(second, "/NookIndexFixture/invoice.txt"); put(second, "/NookIndexFixture/readme.txt")
        _ = try find(first, "r", cursor: isolatedCursor)
        precondition(tryValue { try names(second, "re", cursor: isolatedCursor) } == ["readme.txt"], "replacing a catalog invalidates same-generation cursors")
        nf_destroy(first); nf_destroy(second); nf_cursor_destroy(isolatedCursor)
        nf_remove(index, "/NookIndexFixture/Downloads", 1)
        precondition(tryValue { try names(index, "report") }.count == 3)
        nf_remove(index, "/NookIndexFixture/Desktop/report.pdf", 0)
        precondition(tryValue { try names(index, "report") }.count == 2)
        let replacement = nf_create()!; put(replacement, "/NookIndexFixture/Moved/report-new.pdf"); nf_merge(index, replacement); nf_destroy(replacement)
        precondition(tryValue { try names(index, "report") }.contains("report-new.pdf"))

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nook-files-index-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) } // Only this harness's own generated fixtures.
        let cache = root.appendingPathComponent("index.bin")
        precondition(nf_save(index, cache.path, 123456, 5678) != 0)
        var event: UInt64 = 0
        let loaded = nf_load(cache.path, 5678, &event)!
        precondition(event == 123456 && nf_count(loaded) == nf_count(index))
        precondition(tryValue { try names(loaded, "report") } == tryValue { try names(index, "report") })
        nf_destroy(loaded)
        precondition(nf_load(cache.path, 123, &event) == nil, "changed scope rejects cache")
        var corrupt = try Data(contentsOf: cache); corrupt[corrupt.count - 1] ^= 1; try corrupt.write(to: cache)
        precondition(nf_load(cache.path, 5678, &event) == nil, "corrupt cache is rebuilt")

        let fixture = root.appendingPathComponent("fixtures")
        for path in ["Desktop", "Library", "Developer/node_modules", "Developer/build", "Developer/.git", "Demo.app/Contents", "Keep", ".hidden"] {
            try FileManager.default.createDirectory(at: fixture.appendingPathComponent(path), withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: fixture.appendingPathComponent(path + "/marker.txt"))
        }
        try FileManager.default.createSymbolicLink(atPath: fixture.appendingPathComponent("linked").path, withDestinationPath: fixture.appendingPathComponent("Keep").path)
        let scanned = nf_create()!; defer { nf_destroy(scanned) }
        nf_scan(scanned, fixture.path, "", 0, 0, 0, 0)
        precondition(tryValue { try find(scanned, "marker").total } == 2, "default exclusions and no symlink traversal")
        precondition(tryValue { try names(scanned, "Demo.app") } == ["Demo.app"])
        let expanded = nf_create()!; defer { nf_destroy(expanded) }
        nf_scan(expanded, fixture.path, fixture.appendingPathComponent("Keep").path, 1, 1, 1, 1)
        precondition(tryValue { try find(expanded, "marker").total } == 7, "configurable exclusions and scope")
        print("PASS: query grammar, invalid syntax, unicode/highlights, name tiers, added/modified recency, frecency, full-candidate narrowing, update invalidation, subtree removals, merge, persistence/event watermark/corruption, scanner exclusions, packages and symlinks")
    }
    static func tryValue<T>(_ body: () throws -> T) -> T { try! body() }

    static func percentile(_ values: [Double], _ percentile: Double = 0.5) -> Double { values.sorted()[min(values.count - 1, Int(Double(values.count - 1) * percentile))] }
    static func benchmark() throws {
        if CommandLine.arguments.contains("--synthetic") { try syntheticBenchmark(); return }
        let index = nf_create()!
        let start = CFAbsoluteTimeGetCurrent()
        let policy = FileSearchAccessPolicy(home: NSHomeDirectory(), volumes: FileSearchAccessPolicy.protectedVolumes())
        nf_scan(index, NSHomeDirectory(), policy.exclusions.joined(separator: "\n"), 0, 0, 0, 0)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        print(String(format: "HOME names=%d scan=%.3fs indexAllocated=%.2fMiB processPeakRSS=%.2fMiB skipped=%d", nf_count(index), elapsed, Double(nf_memory(index))/1048576, Double(usage.ru_maxrss)/1048576, nf_skipped(index)))
        try measure(index, label: "HOME")
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("nook-file-benchmark-\(UUID().uuidString).bin")
        let save = CFAbsoluteTimeGetCurrent(); precondition(nf_save(index, cache.path, 42, 1) != 0)
        print(String(format: "HOME cacheSave=%.3fs", CFAbsoluteTimeGetCurrent()-save))
        nf_destroy(index)
        var event: UInt64 = 0
        let load = CFAbsoluteTimeGetCurrent(); let loaded = nf_load(cache.path, 1, &event)!
        print(String(format: "HOME cacheLoad=%.3fs bytes=%d watermark=%llu", CFAbsoluteTimeGetCurrent()-load, (try FileManager.default.attributesOfItem(atPath: cache.path)[.size] as? NSNumber)?.intValue ?? 0, event))
        nf_destroy(loaded); try FileManager.default.removeItem(at: cache) // Harness cache only, under /tmp.
        try syntheticBenchmark()
    }
    static func syntheticBenchmark() throws {
        let synthetic = nf_create()!; defer { nf_destroy(synthetic) }
        let synthStart = CFAbsoluteTimeGetCurrent()
        for i in 0..<1_000_000 {
            let names = ["report", "readme", "package", "swift", "invoice", "photo", "FileSearch", "PLUGINS"]
            put(synthetic, "/NookIndexFixture/Developer/project-\(i / 100)/\(names[i % names.count])-\(i).txt", added: now - Double(i % 365) * 86400)
        }
        print(String(format: "SYNTHETIC names=%d build=%.3fs indexAllocated=%.2fMiB", nf_count(synthetic), CFAbsoluteTimeGetCurrent()-synthStart, Double(nf_memory(synthetic))/1048576))
        try measure(synthetic, label: "SYNTHETIC")
    }
    static func measure(_ index: OpaquePointer, label: String) throws {
        for text in ["", "Nook", "readme", "package", "swift", "FileSearch", "PLUGINS", "report", "invoice", "rpt", "*.png", "ext:pdf;docx added:week"] {
            let query = try FileIndexQuery(text).compiled(scope: "", kind: "all")
            var times: [Double] = [], total = 0, hits = [NFHit](repeating: NFHit(), count: 100)
            for _ in 0..<25 {
                let start = CFAbsoluteTimeGetCurrent()
                _ = nf_search(index, query, nil, &hits, hits.count, &total)
                times.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
            }
            nf_query_destroy(query)
            print(String(format: "%@ query=%@ median=%.3fms p95=%.3fms matches=%d", label, text.isEmpty ? "<Recent>" : text, percentile(times), percentile(times, 0.95), total))
        }
        let cursor = nf_cursor_create()!; defer { nf_cursor_destroy(cursor) }
        for text in ["r", "re", "rea", "read", "readm", "readme"] {
            let start = CFAbsoluteTimeGetCurrent()
            let rows = try find(index, text, cursor: cursor)
            print(String(format: "%@ incremental=%@ latency=%.3fms matches=%d", label, text, (CFAbsoluteTimeGetCurrent()-start)*1000, rows.total))
        }
    }
}
