import Foundation
import Darwin

private enum TestFailure: Error { case failed(String) }
private func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw TestFailure.failed(message) }
}
private func rejects(_ label: String, _ operation: () async throws -> Void) async throws {
    do { try await operation() }
    catch { return }
    throw TestFailure.failed("Expected rejection: \(label)")
}

private final class GitHubMock: URLProtocol {
    static var routes: [String: (Int, Data)] = [:]
    static var offline = false
    static var requests: [String] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let key = request.url!.absoluteString
        Self.requests.append(key)
        if Self.offline { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
        let (status, data) = Self.routes[key] ?? (404, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class TrashMock {
    let root: URL
    var fail = false
    init(_ root: URL) { self.root = root }
    func move(_ source: URL) throws {
        if fail { throw PluginStoreError("Synthetic Trash failure") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: source, to: root.appendingPathComponent(UUID().uuidString))
    }
}

@main private struct StoreClientTests {
    static func main() async throws {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent("nook-store-tests-\(UUID().uuidString)")
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        let root = temporary.resolvingSymlinksInPath()
        defer { try? fm.removeItem(at: root) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GitHubMock.self]
        let session = URLSession(configuration: config)
        let trash = TrashMock(root.appendingPathComponent("Trash"))
        let plugins = root.appendingPathComponent("Plugins")
        let cache = root.appendingPathComponent("Cache")
        let client = PluginStoreClient(pluginsRoot: plugins, cacheRoot: cache, session: session, trash: trash.move)
        let source = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        let entry = try JSONDecoder().decode([PluginStoreEntry].self, from: Data(contentsOf: source.appendingPathComponent("index.json")))[0]
        let original = source.appendingPathComponent(entry.path)
        try expect(try PluginStorePackage.treeSHA(original) == entry.sha, "Swift tree hashing matches generated Node/Git hash")
        try expect(!PluginStorePackage.validID("bad\n"), "Reject newline IDs")
        try expect(!PluginStorePackage.safePath("../escape"), "Reject path traversal")
        try expect(!PluginStorePackage.safePath("x//y"), "Reject empty path components")

        // The repo does not exist yet: this must be a normal empty state, with no writes.
        let missing = try await client.catalog(force: true)
        try expect(missing.plugins.isEmpty && missing.message?.contains("not published") == true, "Missing repo is a friendly empty state")
        try expect(!fm.fileExists(atPath: cache.path), "404 does not create a fake catalog")
        GitHubMock.routes[PluginStoreClient.indexURL.absoluteString] = (200, try JSONEncoder().encode([entry]))
        let fresh = try await client.catalog(force: true)
        try expect(fresh.plugins == [entry] && !fresh.cached, "Fetched catalog")
        GitHubMock.offline = true
        let offline = try await client.catalog(force: true)
        try expect(offline.plugins == [entry] && offline.cached, "Offline cache fallback")
        GitHubMock.offline = false
        GitHubMock.routes[PluginStoreClient.indexURL.absoluteString] = (404, Data())
        let unpublished = try await client.catalog(force: true)
        try expect(unpublished.plugins == [entry], "404 preserves cached catalog")
        let emptyClient = PluginStoreClient(pluginsRoot: root.appendingPathComponent("unused"), cacheRoot: root.appendingPathComponent("empty"), session: session, trash: trash.move)
        GitHubMock.routes[PluginStoreClient.indexURL.absoluteString] = (200, try JSONEncoder().encode([entry, entry]))
        try await rejects("duplicate catalog IDs") { _ = try await emptyClient.catalog(force: true) }
        GitHubMock.offline = true
        try await rejects("offline without cache") { _ = try await emptyClient.catalog(force: true) }
        GitHubMock.offline = false
        print("✓ Catalog: 404, live fetch, cache, offline, duplicate rejection")

        try registerPackage(original, entry: entry)
        try await client.install(entry)
        let destination = plugins.appendingPathComponent(entry.id)
        let installed = await client.installation(entry.id)
        try expect(installed?.receipt?.sha == entry.sha && installed?.version == entry.version, "Installed receipt")
        try expect(try PluginStorePackage.treeSHA(destination) == entry.sha, "Installed package integrity")
        try expect(!GitHubMock.requests.contains { $0.contains("/git/blobs/") }, "Current packages download through raw CDN without per-file API requests")
        try await rejects("install over existing copy") { try await client.install(entry) }
        print("✓ Immutable package download, blob integrity, version receipt, collision refusal")

        let changedRoot = root.appendingPathComponent("fixtures/word-count")
        try fm.createDirectory(at: changedRoot.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: original, to: changedRoot)
        for name in ["plugin.json", "store.json"] {
            let file = changedRoot.appendingPathComponent(name)
            var json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
            json["version"] = "1.1.0"
            try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]).write(to: file)
        }
        let next = PluginStoreEntry(id: entry.id, name: entry.name, description: entry.description, author: entry.author,
            version: "1.1.0", symbol: entry.symbol, tags: entry.tags, screenshots: entry.screenshots,
            path: entry.path, sha: try PluginStorePackage.treeSHA(changedRoot), updatedAt: entry.updatedAt)
        try registerPackage(changedRoot, entry: next)
        let local = destination.appendingPathComponent("local.txt")
        try Data("local edit".utf8).write(to: local)
        try await rejects("preserve edited plugin") { try await client.install(next, update: true) }
        try expect(try String(contentsOf: local, encoding: .utf8) == "local edit", "Local edit unchanged")
        try fm.removeItem(at: local) // Synthetic test fixture only.
        trash.fail = true
        try await rejects("rollback when Trash fails") { try await client.install(next, update: true) }
        let rolledBack = await client.installation(entry.id)
        try expect(rolledBack?.version == entry.version, "Rollback restored original version")
        try expect(try PluginStorePackage.treeSHA(destination) == entry.sha, "Rollback restored original contents")
        trash.fail = false
        try await client.install(next, update: true)
        let updated = await client.installation(entry.id)
        try expect(updated?.version == "1.1.0", "Updated receipt")
        try expect(try fm.contentsOfDirectory(atPath: trash.root.path).count == 1, "Previous copy went through Trash handler")
        print("✓ Updates preserve local edits, roll back on Trash failure, and trash replaced copies")

        let unrelated = plugins.appendingPathComponent("unmanaged")
        try fm.createDirectory(at: unrelated, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: unrelated.appendingPathComponent("plugin.json"))
        let installations = await client.installations()
        try expect(installations["unmanaged"]?.receipt == nil, "Unmanaged copy detected")
        let dataFolder = root.appendingPathComponent("Data")
        try fm.createDirectory(at: dataFolder, withIntermediateDirectories: true)
        let savedData = dataFolder.appendingPathComponent("word-count.json")
        try Data("saved draft".utf8).write(to: savedData)
        try await client.uninstall(entry.id)
        try expect(!fm.fileExists(atPath: destination.path), "Uninstall removed plugin folder")
        try expect(try String(contentsOf: savedData, encoding: .utf8) == "saved draft", "Uninstall preserved saved data")
        try await rejects("uninstall traversal") { try await client.uninstall("../Data") }
        print("✓ Uninstall uses Trash handler and keeps saved data")

        // Corrupt downloads, traversal, symlinks, and GitHub rate limits never create a plugin.
        let fake = PluginStoreEntry(id: entry.id, name: entry.name, description: entry.description, author: entry.author,
            version: entry.version, symbol: entry.symbol, tags: [], screenshots: [], path: entry.path,
            sha: String(repeating: "a", count: 40), updatedAt: entry.updatedAt)
        let endpoint = "https://api.github.com/repos/\(PluginStoreClient.repository)/git/trees/\(fake.sha)?recursive=1"
        for (path, mode) in [("../escape", "100644"), ("symlink", "120000"), ("run.sh", "100755")] {
            GitHubMock.routes[endpoint] = (200, try json(["tree": [["path": path, "mode": mode, "type": "blob", "sha": entry.sha, "size": 1]], "truncated": false]))
            try await rejects("unsafe download \(path)") { try await client.install(fake) }
            try expect(!fm.fileExists(atPath: destination.path), "Rejected package not installed")
        }
        GitHubMock.routes[endpoint] = (429, Data())
        try await rejects("rate limit") { try await client.install(fake) }
        try registerPackage(original, entry: entry)
        let firstFile = try PluginStorePackage.files(original)[0]
        let fileSHA = PluginStorePackage.objectSHA("blob", try Data(contentsOf: firstFile))
        let blobURL = "https://api.github.com/repos/\(PluginStoreClient.repository)/git/blobs/\(fileSHA)"
        let rawURL = "https://raw.githubusercontent.com/\(PluginStoreClient.repository)/main/\(entry.path)/\(try PluginStorePackage.relativePath(firstFile, in: original))"
        let validBlob = GitHubMock.routes[blobURL]
        let validRaw = GitHubMock.routes[rawURL]
        GitHubMock.routes[rawURL] = (200, Data("concurrent main change".utf8))
        GitHubMock.routes[blobURL] = (200, try json(["encoding": "base64", "content": Data("corrupt".utf8).base64EncodedString(), "size": 7]))
        try await rejects("corrupt blob") { try await client.install(entry) }
        try expect(!fm.fileExists(atPath: destination.path), "Corrupt download never installed")
        GitHubMock.routes[blobURL] = validBlob

        let lockURL = cache.appendingPathComponent("\(entry.id).lock")
        let lock = Darwin.open(lockURL.path, O_RDWR)
        try expect(lock >= 0 && flock(lock, LOCK_EX | LOCK_NB) == 0, "Acquire competing process lock")
        try await rejects("cross-process lock") { try await client.install(entry) }
        flock(lock, LOCK_UN); close(lock)
        try await client.install(entry)
        try expect(GitHubMock.requests.contains(blobURL), "A changed raw file falls back to its immutable Git blob")
        try expect(try PluginStorePackage.treeSHA(destination) == entry.sha, "Concurrent main changes cannot mix installed revisions")
        GitHubMock.routes[rawURL] = validRaw
        print("✓ Unsafe trees, corrupt blobs, rate limits, and concurrent operations rejected")

        // Symlink sources are rejected before publishing; tests never touch live Nook data.
        let linked = root.appendingPathComponent("linked")
        try fm.createSymbolicLink(at: linked, withDestinationURL: original)
        try await rejects("symbolic-link source") { _ = try PluginStorePackage.validate(linked) }

        let validationSource = root.appendingPathComponent("validation/word-count")
        try fm.createDirectory(at: validationSource.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: original, to: validationSource)
        let manifestFile = validationSource.appendingPathComponent("plugin.json")
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestFile)) as! [String: Any]
        for order in [-1, 0, 1, 110] {
            var value = manifest
            value["order"] = order
            try json(value).write(to: manifestFile)
            try PluginStorePackage.validate(validationSource)
        }
        let invalidFields: [(String, Any)] = [
            ("order", true), ("order", "first"), ("order", 1.5), ("height", true), ("entry", false), ("symbol", 3),
            ("settings", [["key": "x", "label": "X", "type": "number", "min": 5, "max": 1]]),
            ("settings", [["key": "x", "label": "X", "type": "number", "step": 0]]),
            ("settings", [["key": "x", "label": "X", "type": "select", "options": [1]]]),
            ("settings", [["key": "x", "label": "X", "type": "text", "default": ["nested": true]]])
        ]
        for (key, invalid) in invalidFields {
            var value = manifest
            value[key] = invalid
            try json(value).write(to: manifestFile)
            try await rejects("invalid manifest \(key)") { _ = try PluginStorePackage.validate(validationSource) }
        }
        print("✓ Package manifest types and slider constraints; integer orders 0/1 remain valid")
        print("All Store client checks passed in \(root.path)")
    }

    private static func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }

    private static func registerPackage(_ directory: URL, entry: PluginStoreEntry) throws {
        var tree: [[String: Any]] = []
        for file in try PluginStorePackage.files(directory) {
            let data = try Data(contentsOf: file)
            let sha = PluginStorePackage.objectSHA("blob", data)
            tree.append(["path": try PluginStorePackage.relativePath(file, in: directory), "mode": "100644", "type": "blob", "sha": sha, "size": data.count])
            GitHubMock.routes["https://raw.githubusercontent.com/\(PluginStoreClient.repository)/main/\(entry.path)/\(try PluginStorePackage.relativePath(file, in: directory))"] = (200, data)
            GitHubMock.routes["https://api.github.com/repos/\(PluginStoreClient.repository)/git/blobs/\(sha)"] = (200,
                try json(["encoding": "base64", "size": data.count, "content": data.base64EncodedString()]))
        }
        GitHubMock.routes["https://api.github.com/repos/\(PluginStoreClient.repository)/git/trees/\(entry.sha)?recursive=1"] = (200,
            try json(["tree": tree, "truncated": false]))
    }
}
