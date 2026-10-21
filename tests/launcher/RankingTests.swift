import Foundation

@main
struct RankingTests {
    static func main() throws {
        func check(_ condition: @autoclosure () -> Bool, _ description: String) {
            guard condition() else { fatalError(description) }
        }
        let now = 1_800_000_000.0
        let docs = [
            LauncherSearchDocument(id: "subsequence", source: .applications, title: "Amazing Remote Client"),
            LauncherSearchDocument(id: "word", source: .applications, title: "Google Arc"),
            LauncherSearchDocument(id: "prefix", source: .applications, title: "Arc"),
            LauncherSearchDocument(id: "detail", source: .applications, title: "Browser", detail: "arc"),
            LauncherSearchDocument(id: "command", source: .aiCommands, title: "Rewrite"),
        ]
        let frequent = LauncherUsage(count: 1_000_000, lastUsed: now)
        let ordered = LauncherRanking.ranked(docs, query: LauncherQuery("arc"), history: ["subsequence": frequent], now: now)
        check(ordered == ["prefix", "word", "subsequence", "detail"], "Prefix > word-start > subsequence > subtitle, independent of history")
        check(LauncherRanking.ranked(docs, query: LauncherQuery("zzzz"), history: [:], now: now).isEmpty, "Unmatched results excluded")
        check(LauncherRanking.ranked(docs, query: LauncherQuery("ai: rewrite"), history: [:], now: now) == ["command"], "Source filtering")
        check(LauncherQuery(" APP:  Finder \n").text == "Finder", "Trim and parse source prefix")
        check(LauncherQuery("ai: réécrire").characters == Array("reecrire"), "Diacritic folding")
        check(LauncherQuery("hello: world").source == nil, "Unknown prefix is literal")
        check(LauncherQuery("hello: world").text == "hello: world", "Unknown prefix preserves AI query")
        check(LauncherQuery("app:").characters.isEmpty, "Empty source-specific query")
        check(LauncherQuery("  💡 café  ").text == "💡 café", "Preserve AI prompt Unicode")
        check(LauncherQuery(String(repeating: "x", count: 900)).text.count == 512, "Bound input")
        check(LauncherRanking.ranked(docs, query: LauncherQuery(""), history: ["command": frequent], now: now).first == "command", "Empty search uses frecency")
        check(LauncherRanking.ranked(docs, query: LauncherQuery(""), history: [:], now: now) == docs.map(\.id), "Stable ties")
        check(LauncherUsage(count: 4, lastUsed: now).score(at: now) > LauncherUsage(count: 4, lastUsed: now - 86_400 * 30).score(at: now), "Recency decays")
        check(LauncherUsage(count: 12, lastUsed: now).score(at: now) > LauncherUsage(count: 1, lastUsed: now).score(at: now), "Frequency grows")
        check(LauncherUsage(count: -4, lastUsed: now + 100).score(at: now).isFinite, "Malformed persisted values stay finite")
        var history: [String: LauncherUsage] = [:]
        LauncherUsage.record("app", in: &history, at: now)
        LauncherUsage.record("app", in: &history, at: now + 1)
        check(history["app"] == LauncherUsage(count: 2, lastUsed: now + 1), "Record count and timestamp")
        let restored = try JSONDecoder().decode([String: LauncherUsage].self, from: JSONEncoder().encode(history))
        check(restored == history, "Frecency persistence round trip")
        for i in 0..<550 { LauncherUsage.record("item\(i)", in: &history, at: now + Double(i)) }
        check(history.count == 500, "Bound history")
        check(history["item549"] != nil, "Keep recent launch")
        let long = LauncherSearchDocument(id: "long", source: .plugins, title: String(repeating: "a", count: 3000) + "arc")
        let short = LauncherSearchDocument(id: "short", source: .plugins, title: "a r c")
        check(LauncherRanking.score(LauncherQuery("arc"), document: long, usage: nil, now: now) != nil, "Long subsequences")
        check(LauncherRanking.score(LauncherQuery("a r c"), document: short, usage: nil, now: now) != nil, "Spaces ignored like ⌘K")

        let apps = (0..<500).map { i in LauncherSearchDocument(id: "app\(i)", source: .applications, title: ["Google Chrome", "Visual Studio Code", "Archive Utility", "Activity Monitor", "Safari"][i % 5] + " \(i)", detail: "com.example.application\(i)") }
        var samples: [Double] = []
        for i in 0..<200 {
            let query = LauncherQuery(["arc", "gc", "vis", "app:", "zzzz", "chrome"][i % 6])
            let start = DispatchTime.now().uptimeNanoseconds
            _ = LauncherRanking.ranked(apps, query: query, history: [:], now: now)
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        let p95 = samples.sorted()[190]
        check(p95 < 5, "500-app filtering must stay below 5 ms (p95 \(p95) ms)")
        print(String(format: "Launcher ranking/query/frecency passed. 500 apps: median %.3f ms, p95 %.3f ms, max %.3f ms", samples.sorted()[100], p95, samples.max() ?? 0))
    }
}
