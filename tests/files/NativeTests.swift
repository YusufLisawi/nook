import AppKit
import Foundation

// The real service and registry run without Services.shared or the Nook application lifecycle.
enum PluginEvents {
    static var receive: ((String, Any, String?) -> Void)?
    static func emit(_ event: String, _ payload: Any, to pluginID: String? = nil) { receive?(event, payload, pluginID) }
}

@main
struct NativeTests {
    static func main() throws {
        let domain = "nook.files.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = FileSearchPreferences.Snapshot(defaults: defaults)
        precondition(FileSearchPolicy.matchTier(name: "Résumé.swift", query: "resume") == 3)
        precondition(FileSearchPolicy.matchTier(name: "my resume.swift", query: "resume") == 2)
        precondition(FileSearchPolicy.matchTier(name: "myresume.swift", query: "resume") == 1)
        precondition(FileSearchPolicy.matchTier(name: "FileSearch.swift", query: "search") == 2)
        precondition(FileSearchPolicy.matchTier(name: "other.swift", query: "resume") == -1)
        precondition(FileSearchPolicy.matchTier(name: "[file]*.txt", query: "[file]*") == 3)
        precondition(!preferences.allows("/Users/test/Developer/node_modules/file.txt"))
        precondition(!preferences.allows("/Users/test/Developer/.git/config"))
        precondition(!preferences.allows("/Users/test/Library/Caches/file.txt"))
        precondition(!preferences.allows("/Users/test/.secret/file.txt"))
        precondition(preferences.allows("/Users/test/Library/Documents/file.txt"))
        precondition(!FileSearchPolicy.isInside("/Users/test/Downloads-old/x", root: "/Users/test/Downloads"))
        defaults.set(true, forKey: FileSearchPreferences.hiddenKey)
        defaults.set("/Users/test/Private\n", forKey: FileSearchPreferences.excludedKey)
        let hidden = FileSearchPreferences.Snapshot(defaults: defaults)
        precondition(hidden.allows("/Users/test/.secret/file.txt"))
        precondition(!hidden.allows("/Users/test/Private/x"))
        precondition(hidden.allows("/Users/test/Private-other/x"))
        precondition(!hidden.allows("/Users/test/.git/config"))
        defaults.removeObject(forKey: FileSearchPreferences.hiddenKey)
        defaults.removeObject(forKey: FileSearchPreferences.excludedKey)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nook-files-native-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) } // generated test fixtures only
        let sample = root.appendingPathComponent("preview.swift")
        try Data(String(repeating: "let hello = \"world\"\n", count: 3000).utf8).write(to: sample)
        let preview = try FileSearchPreview.readText(sample)!
        precondition(preview.utf8.count <= FileSearchPreview.textLimit + 3)
        precondition(preview.hasPrefix("let hello"))
        let binary = root.appendingPathComponent("binary.txt")
        try Data([0,1,2,3]).write(to: binary)
        let binaryText = try FileSearchPreview.readText(binary)
        precondition(binaryText == nil)
        do { _ = try FileSearchPreview.fileURL("relative/file"); preconditionFailure("relative path accepted") } catch { }
        do { _ = try FileSearchPreview.fileURL(root.appendingPathComponent("absent-file").path); preconditionFailure("missing file accepted") } catch { }
        let now = Date().timeIntervalSince1970
        func result(_ name: String, lastUsed: Double = 0) -> FileSearchResult {
            FileSearchResult(path: "/tmp/" + name, name: name, kind: "Text", size: 1, modified: now, lastUsed: lastUsed, contentTypes: ["public.text"])
        }
        let prefix = result("resume.swift"), word = result("my resume.swift", lastUsed: now), contains = result("myresume.swift", lastUsed: now)
        let ranked = FileSearchPolicy.ranked([contains, word, prefix], query: "resume", preferences: preferences, usage: [contains.path:1000], now: now)
        precondition(ranked.map(\.path) == [prefix.path, word.path, contains.path], "usage must not cross name tiers")
        let frequent = result("report-b.txt"), recent = result("report-a.txt", lastUsed: now - 29 * 86400)
        precondition(FileSearchPolicy.ranked([recent, frequent], query: "report", preferences: preferences, usage: [frequent.path:10], now: now).first?.path == frequent.path)
        precondition(FileSearchPolicy.ranked([frequent, result("report-c.txt", lastUsed: now)], query: "report", preferences: preferences, usage: [:], now: now).first?.name == "report-c.txt")
        precondition(result("Search.ts").category == "code")
        precondition(result("settings.yaml").category == "code")
        var invisible = result("report-hidden.txt", lastUsed: now)
        invisible.hidden = true
        precondition(FileSearchPolicy.ranked([invisible], query: "report", preferences: preferences, usage: [:]).isEmpty)
        print("PASS: match tiers, accents, literal queries, hidden/excluded folders, path boundaries, bounded text, binary detection, missing paths")

        precondition(FileSearchPolicy.ranked([prefix], query: "", preferences: preferences, usage: [:]).isEmpty, "recent cache must exclude never-used files")
        // NSMetadataQuery throws Objective-C exceptions for unsupported predicate shapes.
        // Exercise translation, especially the default empty/recent query, even without --benchmark.
        for (text, kind) in [("", "all"), ("literal ' * [x]", "all"), ("swift", "code")] {
            let query = NSMetadataQuery()
            query.predicate = FileSearchPolicy.predicate(query: text, kind: kind)
            query.searchScopes = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")]
            precondition(query.start(), "Spotlight rejected a file-search predicate")
            query.stop()
        }
        let previewer = FileSearchPreview()
        func loadPreview(_ url: URL) -> [String: Any] {
            var value: [String: Any]?, failure: String?, completed = false
            previewer.load(url) { result, error in
                value = result as? [String: Any]; failure = error; completed = true
            }
            let deadline = Date().addingTimeInterval(4)
            while !completed && Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
            precondition(completed && failure == nil && value != nil, "preview failed: \(failure ?? "timeout")")
            return value!
        }
        let textPayload = loadPreview(sample)
        precondition(textPayload["path"] as? String == sample.path && textPayload["truncated"] as? Bool == true)
        precondition((textPayload["text"] as? String)?.hasPrefix("let hello") == true)
        let context = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        let image = root.appendingPathComponent("preview.png")
        try NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!.write(to: image)
        let imagePayload = loadPreview(image)
        precondition((imagePayload["thumbnail"] as? String)?.hasPrefix("data:image/png;base64,") == true, "QuickLookThumbnailing did not return a PNG")
        print("PASS: real bounded text/metadata preview and QuickLookThumbnailing PNG, without displaying a window")
        let filters = CommandLine.arguments.contains("--filters")
        guard filters || CommandLine.arguments.contains("--benchmark") else { return }
        let service = FileSearchService(defaults: defaults)
        service.register()
        let terms = filters ? ["swift", "Nook", "Nook", "report", "image", "PLUGINS", ""] : ["Nook", "readme", "package", "swift", "Nook", "readme", "package", "swift", "FileSearch", "PLUGINS", "report", "invoice"]
        let kinds = filters ? ["code", "folder", "app", "pdf", "image", "document", "all"] : Array(repeating: "all", count: terms.count)
        let scopes = filters ? ["Developer", "home", "all", "home", "home", "Developer", "Downloads"] : Array(repeating: "home", count: terms.count)
        var index = 0, generation = 0, completed = false
        var start = Date(), firstMs: Int?, gotRows = false
        var finish: (() -> Void)!
        var next: (() -> Void)!
        finish = {
            guard !completed else { return }; completed = true
            print("SPOTLIGHT query=\(terms[index]) kind=\(kinds[index]) scope=\(scopes[index]) firstNonemptyMs=\(firstMs.map(String.init) ?? "none") finishedMs=\(Int(Date().timeIntervalSince(start) * 1000)) nonempty=\(gotRows)")
            _ = BridgeRegistry.handle("files.cancel", args: ["benchmark"], pluginID: "native-test") { _, _ in }
            index += 1
            if index == terms.count { PluginEvents.receive = nil; print("PASS: real Spotlight engine started, streamed, and cancelled without launching Nook"); return }
            DispatchQueue.main.async { next() }
        }
        next = {
            completed = false; start = Date(); firstMs = nil; gotRows = false; generation += 1
            let current = generation
            _ = BridgeRegistry.handle("files.search", args: [terms[index], ["clientID":"benchmark", "requestID":String(current), "scope":scopes[index], "kind":kinds[index], "limit":60]], pluginID: "native-test") { result, error in
                precondition(error == nil)
                if let payload = result as? [String: Any], let rows = payload["results"] as? [[String: Any]], !rows.isEmpty {
                    firstMs = Int(Date().timeIntervalSince(start) * 1000); gotRows = true
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { if current == generation { finish() } }
        }
        PluginEvents.receive = { event, value, plugin in
            guard event == "files", plugin == "native-test", let payload = value as? [String: Any], payload["requestID"] as? String == String(generation) else { return }
            precondition(payload["error"] == nil, "Spotlight failed: \(payload)")
            let rows = payload["results"] as? [[String: Any]] ?? []
            precondition(Set(rows.compactMap { $0["path"] as? String }).count == rows.count, "duplicate result paths")
            if !rows.isEmpty {
                if firstMs == nil { firstMs = Int(Date().timeIntervalSince(start) * 1000) }
                gotRows = true
                for row in rows {
                    let path = row["path"] as! String
                    precondition(preferences.allows(path))
                    if scopes[index] == "Developer" || scopes[index] == "Downloads" {
                        precondition(FileSearchPolicy.isInside(path, root: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(scopes[index]).path))
                    }
                    if kinds[index] == "document" { precondition(["document", "pdf"].contains(row["category"] as? String ?? "")) }
                    else if kinds[index] != "all" { precondition(row["category"] as? String == kinds[index], "wrong kind: \(row)") }
                }
            }
            if payload["gathering"] as? Bool == false { finish() }
        }
        next()
        while index < terms.count { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
    }
}
