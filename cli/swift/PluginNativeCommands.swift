import Foundation

enum PluginNativeCommands {
    static func scaffold(id: String, language: String, parent: URL, templates: URL, name: String, symbol: String) throws {
        guard PluginStorePackage.validID(id), ["swift", "rust", "node", "python"].contains(language) else { throw PluginEngineError("Usage: nook new <id> --native swift|rust|node|python [--output <parent>]") }
        let destination = parent.appendingPathComponent(id)
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw PluginEngineError("\(destination.path) already exists.") }
        let web = templates.appendingPathComponent("web"), native = templates.appendingPathComponent(language)
        guard FileManager.default.fileExists(atPath: web.appendingPathComponent("index.html").path), FileManager.default.fileExists(atPath: native.path) else { throw PluginEngineError("Native templates not found at \(templates.path). Set NOOK_RESOURCES for a development CLI.") }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for root in [web, native] {
            for file in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
                try FileManager.default.copyItem(at: file, to: destination.appendingPathComponent(file.lastPathComponent))
            }
        }
        var helper: [String: Any] = ["background": false, "permissions": []]
        if language == "node" { helper["run"] = ["node", "helper.mjs"] }
        else if language == "python" { helper["run"] = ["python3", "helper.py"] }
        else { helper["command"] = "bin/helper" }
        let manifest: [String: Any] = ["id": id, "name": name, "symbol": symbol, "entry": "index.html", "height": 210, "version": "1.0.0", "apiVersion": 2, "native": helper]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: destination.appendingPathComponent("plugin.json"))
        let metadata: [String: Any] = ["author": "YourName", "version": "1.0.0", "description": "A Nook plugin with an isolated \(language) helper.", "tags": ["native"], "screenshots": []]
        try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]).write(to: destination.appendingPathComponent("store.json"))
        print("Created \(destination.path)")
        if language == "swift" || language == "rust" { print("Build first: bash '\(destination.appendingPathComponent("build.sh").path)' (Rust needs both macOS targets and serde_json).") }
        print("Then: nook validate '\(destination.path)' · nook dev '\(destination.path)'\nApprove Developer access in Settings before running the helper.")
    }

    /// Mirror the source into the watched plugin directory. Never launch the app, build scripts, or feature code.
    static func dev(source: URL, plugins: URL, support: URL, once: Bool) throws {
        let manifest = try PluginManifestV2(directory: source)
        guard source.lastPathComponent == manifest.id else { throw PluginEngineError("Folder name must match plugin id.") }
        let destination = plugins.appendingPathComponent(manifest.id)
        guard source.standardizedFileURL != destination.standardizedFileURL else {
            print("Already in Nook's watched plugin folder. Save files to hot-reload."); return
        }
        let leases = support.appendingPathComponent("Dev", isDirectory: true)
        let lease = leases.appendingPathComponent(manifest.id + ".json")
        var previous = (try? Data(contentsOf: lease)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
        if FileManager.default.fileExists(atPath: destination.path), previous?["source"] != source.path { throw PluginEngineError("A different plugin already exists at \(destination.path). Preserve it before using nook dev.") }
        var lastHash = ""
        func sync() throws {
            let currentManifest = try PluginManifestV2(directory: source)
            guard currentManifest.id == manifest.id else { throw PluginEngineError("Stop dev before changing the plugin id.") }
            let digest = try PluginStorePackage.packageSHA256(source)
            guard digest != lastHash else { return }
            if FileManager.default.fileExists(atPath: destination.path) {
                guard let expected = previous?["sha256"], try PluginStorePackage.packageSHA256(destination) == expected else { throw PluginEngineError("The installed dev copy changed. Back it up before syncing again.") }
            }
            try FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: leases, withIntermediateDirectories: true)
            let stage = plugins.appendingPathComponent(".dev-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: stage) } // Generated staging only.
            try FileManager.default.copyItem(at: source, to: stage)
            guard try PluginStorePackage.packageSHA256(stage) == digest else { throw PluginEngineError("Source changed during sync. Save and retry.") }
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.trashItem(at: destination, resultingItemURL: nil) }
            try FileManager.default.moveItem(at: stage, to: destination)
            previous = ["source": source.path, "sha256": digest]
            try JSONSerialization.data(withJSONObject: previous!).write(to: lease, options: .atomic)
            lastHash = digest
            print("Synced \(manifest.id). Nook reloads its UI/helper; approval is required before execution.")
        }
        try sync()
        if once { return }
        print("Watching \(source.path). Ctrl-C stops watching; the dev copy remains installed. Nook must already be running.")
        // Polling only in this development CLI, not in Nook. Fingerprints include nested sources/binaries and modes.
        let timer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { _ in
            do { try sync() } catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)) }
        }
        RunLoop.current.add(timer, forMode: .default)
        RunLoop.current.run()
    }
}
