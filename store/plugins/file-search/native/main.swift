import AppKit
@main enum FileSearchHelper {
    static var observer: NSObjectProtocol?
    static func main() {
        guard PluginRuntime.id == "file-search" else { return }
        if !CommandLine.arguments.contains("--protocol-test") {
            PluginDefaults.standard.migrate(prefixes: ["files.", "launcher.sources"])
            if PluginDefaults.standard.object(forKey: "contributeSearch") == nil, let sources = PluginDefaults.standard.stringArray(forKey: "launcher.sources") { PluginDefaults.standard.set(sources.contains("files"), forKey: "contributeSearch") }
            // Old app grants never authorize a different helper identity.
            PluginDefaults.standard.set([], forKey: "files.grantedFolders")
            PluginDefaults.standard.set(false, forKey: "files.protectedFoldersRequested")
            do {
                try PluginRuntime.copyLegacy(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/com.yusuf.nook/FileIndex"), to: PluginRuntime.data.appendingPathComponent("FileIndex"))
            } catch { PluginEvents.emit("error", "Index cache migration failed: " + error.localizedDescription) }
        }
        let service = FileSearchService.shared
        PluginRuntime.onReady = {
            PluginRuntime.host("files.scopes") { value, error in
                guard error == nil else { return }
                PluginRuntime.scopes = value as? [String] ?? []
                PluginDefaults.standard.set(PluginRuntime.scopes, forKey: "files.grantedFolders")
                PluginDefaults.standard.set(true, forKey: "files.protectedFoldersRequested")
                service.register()
                observer = NotificationCenter.default.addObserver(forName: FileNameIndex.changed, object: nil, queue: .main) { _ in PluginEvents.emit("searchChanged", NSNull()) }
                PluginEvents.emit("ready", NSNull())
            }
        }
        PluginRuntime.onStop = { FileSearchService.disable() }
        PluginRuntime.custom = { method, p, reply in
            if method == "launcher.search" {
                if PluginDefaults.standard.object(forKey: "contributeSearch") as? Bool == false { reply(["items": []], nil); return true }
                let parsed = p["query"] as? String ?? ""
                let query = parsed.hasPrefix("file:") ? String(parsed.dropFirst(5)) : parsed.hasPrefix("f ") ? String(parsed.dropFirst(2)) : parsed
                guard query.count >= 2 else { reply(["items": []], nil); return true }
                service.handle("search", args: [query, ["clientID": "launcher", "limit": 8]], pluginID: "launcher") { value, error in
                    let rows = (value as? [String: Any])?["results"] as? [[String: Any]] ?? []
                    reply(["items": rows.map { ["id": $0["path"] ?? "", "title": $0["name"] ?? "", "subtitle": $0["path"] ?? "", "symbol": "doc", "kind": "File"] }], error)
                }; return true
            }
            if method == "launcher.activate" {
                service.handle(p["alternate"] as? Bool == true ? "reveal" : "open", args: [p["id"] ?? ""], reply: reply); return true
            }
            return false
        }
        PluginRuntime.run()
    }
}
