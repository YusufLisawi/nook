import Foundation

private func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw PluginEngineError("FAIL: " + message) }
}
private func rejects(_ body: () async throws -> Void) async throws {
    do { try await body() } catch { return }; throw PluginEngineError("Expected rejection")
}
private final class FakeStore: URLProtocol {
    static var routes: [String: Data] = [:]
    static var offline = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if Self.offline { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
        let data = Self.routes[request.url!.absoluteString]
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: data == nil ? 404 : 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data ?? Data()); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main enum StoreV2Tests {
    static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("nook-engine-store-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let store = URL(fileURLWithPath: CommandLine.arguments[1])
        var entry = try JSONDecoder().decode([PluginStoreEntry].self, from: Data(contentsOf: store.appendingPathComponent("index.json"))).first { $0.id == "mouse" }!
        let package = store.appendingPathComponent(entry.path)
        try expect(entry.default == true && entry.sha256?.count == 64, "Store default flag and SHA-256")
        try expect(try PluginStorePackage.treeSHA(package) == entry.sha, "Git executable-mode tree matches Node")
        try expect(try PluginStorePackage.packageSHA256(package) == entry.sha256, "Swift and Node canonical SHA-256 agree")
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FakeStore.self]
        let plugins = root.appendingPathComponent("Plugins"), cache = root.appendingPathComponent("Cache")
        let trash = root.appendingPathComponent("Trash")
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        let client = PluginStoreClient(pluginsRoot: plugins, cacheRoot: cache, session: URLSession(configuration: config), trash: { url in try fm.moveItem(at: url, to: trash.appendingPathComponent(UUID().uuidString)) })
        try register(package, entry)
        FakeStore.routes[PluginStoreClient.indexURL.absoluteString] = try JSONEncoder().encode([entry])
        let catalog = try await client.catalog(force: true)
        try expect(catalog.plugins.first?.default == true, "Default plugins fetched from fake Store")
        FakeStore.offline = true
        let offline = try await client.catalog(force: true)
        try expect(offline.cached && offline.plugins == [entry], "Offline Store keeps cached defaults")
        FakeStore.offline = false
        let original = entry
        entry.sha256 = String(repeating: "0", count: 64)
        try await rejects { try await client.install(entry, approve: { _, _ in throw PluginEngineError("Approval should not be reached") }) }
        let afterCorruption = await client.installation(entry.id)
        try expect(afterCorruption == nil, "Digest mismatch never installs")
        entry.sha256 = nil
        try await rejects { try await client.install(entry) }
        entry = original
        try await client.install(entry, approve: { json, directory in
            let manifest = try PluginManifestV2(json: json, directory: directory)
            try expect(manifest.requested == ["accessibility", "background"], "Review the downloaded verified manifest")
        })
        let destination = plugins.appendingPathComponent(entry.id)
        try expect(fm.isExecutableFile(atPath: destination.appendingPathComponent("bin/helper").path), "Download preserves executable mode")
        let saved = root.appendingPathComponent("Data/mouse.json")
        try fm.createDirectory(at: saved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("keep me".utf8).write(to: saved)

        let updated = root.appendingPathComponent("fixture/mouse")
        try fm.createDirectory(at: updated.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: package, to: updated)
        for filename in ["plugin.json", "store.json"] {
            let file = updated.appendingPathComponent(filename)
            var object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
            object["version"] = "2.0.1"
            if filename == "plugin.json" { var native = object["native"] as! [String: Any]; native["permissions"] = ["accessibility", "background", "clipboard"]; object["native"] = native }
            try JSONSerialization.data(withJSONObject: object).write(to: file)
        }
        var next = PluginStoreEntry(id: entry.id, name: entry.name, description: entry.description, author: entry.author, version: "2.0.1", symbol: entry.symbol, tags: entry.tags, screenshots: [], path: entry.path, sha: try PluginStorePackage.treeSHA(updated), updatedAt: entry.updatedAt)
        next.sha256 = try PluginStorePackage.packageSHA256(updated)
        try register(updated, next)
        try await rejects {
            try await client.install(next, update: true, approve: { json, directory in
                let manifest = try PluginManifestV2(json: json, directory: directory)
                let old = PluginPermissionGrant(permissions: ["accessibility", "background"], native: true, fileScopes: [])
                try expect(!old.allows(manifest), "Expanded permissions require review")
                throw PluginEngineError("User declined added clipboard access")
            })
        }
        try expect(try PluginStorePackage.treeSHA(destination) == entry.sha, "Declining update keeps old package intact")
        try await client.install(next, update: true, approve: { _, _ in })
        try expect(try PluginStorePackage.treeSHA(destination) == next.sha, "Approved update swaps the complete verified package")
        try expect(try fm.contentsOfDirectory(atPath: trash.path).count == 1, "Previous version moved to injected Trash")
        try expect(try String(contentsOf: saved, encoding: .utf8) == "keep me", "Update preserves plugin data")
        try await client.uninstall(next.id)
        try expect(try String(contentsOf: saved, encoding: .utf8) == "keep me", "Uninstall preserves plugin data")
        print("PASS: Fake Store defaults/offline, executable files, SHA-256, permission-change review, staged update, Trash and data retention.")
    }

    private static func register(_ directory: URL, _ entry: PluginStoreEntry) throws {
        let files = try PluginStorePackage.files(directory)
        var tree: [[String: Any]] = []
        for file in files {
            let path = try PluginStorePackage.relativePath(file, in: directory), data = try Data(contentsOf: file)
            let sha = PluginStorePackage.objectSHA("blob", data)
            tree.append(["path": path, "type": "blob", "mode": FileManager.default.isExecutableFile(atPath: file.path) ? "100755" : "100644", "sha": sha, "size": data.count])
            FakeStore.routes["https://raw.githubusercontent.com/\(PluginStoreClient.repository)/main/\(entry.path)/\(path)"] = data
            FakeStore.routes["https://api.github.com/repos/\(PluginStoreClient.repository)/git/blobs/\(sha)"] = try JSONSerialization.data(withJSONObject: ["encoding": "base64", "content": data.base64EncodedString(), "size": data.count])
        }
        FakeStore.routes["https://api.github.com/repos/\(PluginStoreClient.repository)/git/trees/\(entry.sha)?recursive=1"] = try JSONSerialization.data(withJSONObject: ["tree": tree, "truncated": false])
    }
}
