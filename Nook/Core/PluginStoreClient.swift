import CryptoKit
import CoreFoundation
import Darwin
import Foundation

struct PluginStoreEntry: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let description: String
    let author: String
    let version: String
    let symbol: String
    let tags: [String]
    let screenshots: [String]
    let path: String
    /// SHA-1 of the plugin's Git tree, not a mutable branch name.
    let sha: String
    let updatedAt: String

    func matches(_ query: String) -> Bool {
        query.isEmpty || ([id, name, description, author] + tags).joined(separator: " ")
            .localizedCaseInsensitiveContains(query)
    }

    func screenshotURL(_ path: String) -> URL? {
        guard PluginStorePackage.safePath(path) else { return nil }
        return URL(string: "https://raw.githubusercontent.com/\(PluginStoreClient.repository)/main/\(self.path)/")?
            .appendingPathComponent(path)
    }
}

struct PluginStoreCatalog {
    var plugins: [PluginStoreEntry]
    var cached: Bool
    var message: String?
}

struct PluginStoreReceipt: Codable, Equatable {
    let id: String
    let version: String
    let sha: String
    let repository: String
}

struct PluginStoreInstallation: Equatable {
    let version: String?
    let receipt: PluginStoreReceipt?
}

struct PluginStoreError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Shared by the app and CLI. Initialization never creates or changes user files.
actor PluginStoreClient {
    static let repository = "YusufLisawi/nook-plugins"
    static let indexURL = URL(string: "https://raw.githubusercontent.com/\(repository)/main/index.json")!
    static let receiptName = ".nook-store.json"
    static let defaultPlugins = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Nook/Plugins", isDirectory: true)
    static let defaultCache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("com.yusuf.nook/PluginStore", isDirectory: true)

    let pluginsRoot: URL
    let cacheRoot: URL
    private let session: URLSession
    private let trash: (URL) throws -> Void
    private let fm = FileManager.default

    init(pluginsRoot: URL = defaultPlugins, cacheRoot: URL = defaultCache, session: URLSession? = nil,
         trash: @escaping (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) {
        self.pluginsRoot = pluginsRoot
        self.cacheRoot = cacheRoot
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 45
        self.session = session ?? URLSession(configuration: config)
        self.trash = trash
    }

    private var cacheFile: URL { cacheRoot.appendingPathComponent("index.json") }

    func cachedCatalog() -> PluginStoreCatalog? {
        guard let data = try? Data(contentsOf: cacheFile), let plugins = try? decodeCatalog(data) else { return nil }
        return PluginStoreCatalog(plugins: plugins, cached: true, message: "Showing the saved catalog.")
    }

    func catalog(force: Bool = false) async throws -> PluginStoreCatalog {
        let cached = cachedCatalog()
        let modified = (try? cacheFile.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if !force, let modified, Date().timeIntervalSince(modified) < 900, let cached { return cached }
        do {
            var request = URLRequest(url: Self.indexURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw PluginStoreError("The Store returned an invalid response.") }
            if http.statusCode == 404 {
                return PluginStoreCatalog(plugins: cached?.plugins ?? [], cached: cached != nil,
                    message: cached == nil ? "The community Store is not published yet. Check back soon." : "The Store is unavailable. Showing the saved catalog.")
            }
            try check(http)
            let entries = try decodeCatalog(data)
            // Failure to cache must not prevent browsing a successfully fetched catalog.
            try? fm.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
            try? data.write(to: cacheFile, options: .atomic)
            return PluginStoreCatalog(plugins: entries, cached: false, message: nil)
        } catch {
            if var cached {
                cached.message = "Couldn't refresh the Store. Showing the saved catalog. \(error.localizedDescription)"
                return cached
            }
            throw PluginStoreError("Couldn't load the Store. Check your connection and try again. \(error.localizedDescription)")
        }
    }

    private func decodeCatalog(_ data: Data) throws -> [PluginStoreEntry] {
        guard data.count <= 2_000_000 else { throw PluginStoreError("The Store catalog is too large.") }
        let entries = try JSONDecoder().decode([PluginStoreEntry].self, from: data)
        guard entries.count <= 2_000, Set(entries.map(\.id)).count == entries.count else {
            throw PluginStoreError("The Store catalog contains too many entries or duplicate IDs.")
        }
        for entry in entries {
            guard PluginStorePackage.validID(entry.id), entry.path == "plugins/\(entry.id)",
                  PluginStorePackage.isSHA(entry.sha), PluginStorePackage.validVersion(entry.version),
                  !entry.name.isEmpty, !entry.description.isEmpty, !entry.author.isEmpty,
                  entry.screenshots.allSatisfy(PluginStorePackage.safePath) else {
                throw PluginStoreError("The Store has an invalid entry: \(entry.id).")
            }
        }
        return entries.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func installation(_ id: String) -> PluginStoreInstallation? {
        guard PluginStorePackage.validID(id) else { return nil }
        let directory = pluginsRoot.appendingPathComponent(id)
        guard fm.fileExists(atPath: directory.path) else { return nil }
        let manifest = (try? Data(contentsOf: directory.appendingPathComponent("plugin.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let receipt = (try? Data(contentsOf: directory.appendingPathComponent(Self.receiptName)))
            .flatMap { try? JSONDecoder().decode(PluginStoreReceipt.self, from: $0) }
        let managed = receipt.flatMap { $0.id == id && $0.repository == Self.repository ? $0 : nil }
        return PluginStoreInstallation(version: managed?.version ?? manifest?["version"] as? String, receipt: managed)
    }

    func installations() -> [String: PluginStoreInstallation] {
        let ids = (try? fm.contentsOfDirectory(atPath: pluginsRoot.path)) ?? []
        return Dictionary(uniqueKeysWithValues: ids.compactMap { id in installation(id).map { (id, $0) } })
    }

    func install(_ entry: PluginStoreEntry, update: Bool = false) async throws {
        guard PluginStorePackage.validID(entry.id), PluginStorePackage.isSHA(entry.sha), entry.path == "plugins/\(entry.id)" else {
            throw PluginStoreError("Invalid Store plugin.")
        }
        let lock = try acquireLock(entry.id)
        defer { flock(lock, LOCK_UN); close(lock) }
        let destination = pluginsRoot.appendingPathComponent(entry.id, isDirectory: true)
        let current = installation(entry.id)
        if let current {
            guard update, let receipt = current.receipt else {
                throw PluginStoreError("\(entry.id) already exists. Uninstall the local copy before installing from the Store.")
            }
            guard try PluginStorePackage.treeSHA(destination) == receipt.sha else {
                throw PluginStoreError("\(entry.id) has local edits. Back them up, then uninstall and reinstall to get the Store version.")
            }
        } else if update { throw PluginStoreError("\(entry.id) is not installed.") }
        let stage = cacheRoot.appendingPathComponent("stage-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stage) } // Only generated download files, never an installed copy.
        let package = stage.appendingPathComponent(entry.id, isDirectory: true)
        try fm.createDirectory(at: package, withIntermediateDirectories: true)
        try await download(entry, to: package)
        let metadata = try PluginStorePackage.validate(package)
        guard metadata["version"] as? String == entry.version,
              try PluginStorePackage.treeSHA(package) == entry.sha else {
            throw PluginStoreError("The downloaded plugin does not match the catalog. Refresh the Store and try again.")
        }
        let receipt = PluginStoreReceipt(id: entry.id, version: entry.version, sha: entry.sha, repository: Self.repository)
        try JSONEncoder().encode(receipt).write(to: package.appendingPathComponent(Self.receiptName), options: .atomic)
        try fm.createDirectory(at: pluginsRoot, withIntermediateDirectories: true)
        // Reject symlink roots/destinations and recheck immediately before swapping.
        // Compare paths: resolving a not-yet-created directory drops its URL's trailing slash.
        guard pluginsRoot.resolvingSymlinksInPath().standardizedFileURL.path == pluginsRoot.standardizedFileURL.path,
              destination.resolvingSymlinksInPath().standardizedFileURL.path == destination.standardizedFileURL.path else {
            throw PluginStoreError("The plugin installation path must not be a symbolic link.")
        }
        if let current {
            guard installation(entry.id) == current,
                  try PluginStorePackage.treeSHA(destination) == current.receipt?.sha else {
                throw PluginStoreError("The installed plugin changed while downloading. Try again.")
            }
            let backup = cacheRoot.appendingPathComponent("backup-\(entry.id)-\(UUID().uuidString)")
            try fm.moveItem(at: destination, to: backup)
            do {
                try fm.moveItem(at: package, to: destination)
                try trash(backup)
            } catch {
                // Restore the old user copy. A failed rollback leaves it at the reported backup path.
                do {
                    if fm.fileExists(atPath: destination.path) { try fm.moveItem(at: destination, to: package) }
                    try fm.moveItem(at: backup, to: destination)
                } catch {
                    throw PluginStoreError("Couldn't restore the previous plugin. Your copy is preserved at \(backup.path).")
                }
                throw error
            }
        } else {
            try fm.moveItem(at: package, to: destination) // Fails safely if a local copy appeared meanwhile.
        }
    }

    func uninstall(_ id: String) throws {
        guard PluginStorePackage.validID(id) else { throw PluginStoreError("Invalid plugin ID.") }
        let lock = try acquireLock(id)
        defer { flock(lock, LOCK_UN); close(lock) }
        let directory = pluginsRoot.appendingPathComponent(id)
        guard fm.fileExists(atPath: directory.path) else { throw PluginStoreError("\(id) is not installed in your Plugins folder.") }
        guard pluginsRoot.resolvingSymlinksInPath().standardizedFileURL.path == pluginsRoot.standardizedFileURL.path else {
            throw PluginStoreError("The Plugins folder must not be a symbolic link.")
        }
        try trash(directory)
    }

    private func acquireLock(_ id: String) throws -> Int32 {
        try fm.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        let file = cacheRoot.appendingPathComponent("\(id).lock")
        let descriptor = Darwin.open(file.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw PluginStoreError("Couldn't lock the plugin installation.") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw PluginStoreError("Another Store operation is already working on \(id). Try again when it finishes.")
        }
        return descriptor
    }

    private struct GitTree: Decodable {
        struct File: Decodable { let path: String; let mode: String; let type: String; let sha: String; let size: Int? }
        let tree: [File]
        let truncated: Bool?
    }
    private struct GitBlob: Decodable { let encoding: String; let content: String; let size: Int }

    private func download(_ entry: PluginStoreEntry, to directory: URL) async throws {
        let data = try await api("git/trees/\(entry.sha)?recursive=1")
        let tree = try JSONDecoder().decode(GitTree.self, from: data)
        guard tree.truncated != true else { throw PluginStoreError("GitHub returned an incomplete plugin tree.") }
        var total = 0
        var fileCount = 0
        var seen = Set<String>()
        for file in tree.tree {
            guard PluginStorePackage.safePath(file.path), PluginStorePackage.isSHA(file.sha),
                  seen.insert(file.path.lowercased()).inserted else { throw PluginStoreError("The plugin contains an unsafe or duplicate path.") }
            if file.type == "tree", file.mode == "040000" { continue }
            guard file.type == "blob", file.mode == "100644", let size = file.size, size >= 0, size <= 5_000_000 else {
                throw PluginStoreError("Plugins may only contain regular, non-executable files up to 5 MB.")
            }
            fileCount += 1
            guard fileCount <= 200 else { throw PluginStoreError("Plugins are limited to 200 files.") }
            total += size
            guard total <= 20_000_000 else { throw PluginStoreError("This plugin exceeds the 20 MB limit.") }
            let contents = try await contents(of: file, in: entry, size: size)
            let target = directory.appendingPathComponent(file.path)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: target, options: .atomic)
        }
    }

    private func contents(of file: GitTree.File, in entry: PluginStoreEntry, size: Int) async throws -> Data {
        // The raw CDN avoids spending a rate-limited API request on every file. Accept
        // current-main bytes only if they match the immutable tree. Older revisions,
        // a concurrent main update, or CDN failures fall back to the exact Git blob.
        let raw = URL(string: "https://raw.githubusercontent.com/\(Self.repository)/main/")!
            .appendingPathComponent(entry.path).appendingPathComponent(file.path)
        if let (data, response) = try? await session.data(from: raw),
           (response as? HTTPURLResponse)?.statusCode == 200, data.count == size,
           PluginStorePackage.objectSHA("blob", data) == file.sha { return data }
        try Task.checkCancellation()
        let blob = try JSONDecoder().decode(GitBlob.self, from: await api("git/blobs/\(file.sha)"))
        guard blob.encoding == "base64", let contents = Data(base64Encoded: blob.content, options: .ignoreUnknownCharacters),
              contents.count == size, blob.size == size, PluginStorePackage.objectSHA("blob", contents) == file.sha else {
            throw PluginStoreError("A downloaded file failed its integrity check.")
        }
        return contents
    }

    private func api(_ path: String) async throws -> Data {
        let url = URL(string: "https://api.github.com/repos/\(Self.repository)/\(path)")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Nook-Plugin-Store", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw PluginStoreError("GitHub returned an invalid response.") }
        try check(http)
        guard data.count <= 8_000_000 else { throw PluginStoreError("GitHub returned an oversized response.") }
        return data
    }

    private func check(_ response: HTTPURLResponse) throws {
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 403 || response.statusCode == 429 {
                throw PluginStoreError("GitHub is limiting requests. Try again later.")
            }
            if response.statusCode == 404 { throw PluginStoreError("This plugin revision is no longer available. Refresh the Store.") }
            throw PluginStoreError("GitHub returned HTTP \(response.statusCode). Try again later.")
        }
    }
}

/// Package constraints are intentionally stricter than the basic local plugin loader.
enum PluginStorePackage {
    static func relativePath(_ file: URL, in root: URL) throws -> String {
        // Foundation's enumerator can canonicalize /var to /private/var on macOS.
        let base = root.resolvingSymlinksInPath().pathComponents
        let components = file.resolvingSymlinksInPath().pathComponents
        guard components.starts(with: base), components.count > base.count else {
            throw PluginStoreError("A plugin file is outside its package folder.")
        }
        return components.dropFirst(base.count).joined(separator: "/")
    }

    static func validID(_ id: String) -> Bool { matches(id, "^[a-z0-9][a-z0-9-]{0,79}\\z") }
    static func isSHA(_ sha: String) -> Bool { matches(sha, "^[a-f0-9]{40}\\z") }
    static func validVersion(_ version: String) -> Bool { matches(version, "^[0-9]+\\.[0-9]+\\.[0-9]+(?:-[0-9A-Za-z.-]+)?\\z") }
    static func matches(_ text: String, _ pattern: String) -> Bool { text.range(of: pattern, options: .regularExpression) != nil }
    private static func number(_ value: Any) -> Double? {
        // JSONSerialization bridges 0/1 to Bool as well as Double; check the CF type.
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        return value.doubleValue
    }
    static func safePath(_ path: String) -> Bool {
        !path.isEmpty && path.utf8.count <= 500 && !path.hasPrefix("/") && !path.contains("\\") &&
            path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
                !$0.isEmpty && !$0.hasPrefix(".") && !$0.contains(":") && !$0.contains(where: { $0.isNewline || $0.asciiValue.map { $0 < 32 || $0 == 127 } == true })
            }
    }

    static func files(_ root: URL) throws -> [URL] {
        let fm = FileManager.default
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else { throw PluginStoreError("The plugin folder must be a real directory.") }
        var enumerationError: Error?
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey], options: [], errorHandler: { _, error in enumerationError = error; return false }) else {
            throw PluginStoreError("Couldn't read the plugin folder.")
        }
        var result: [URL] = []
        var seen = Set<String>()
        var total = 0
        for case let url as URL in enumerator {
            // Inspect the original URL before canonicalizing it, so links cannot hide their type.
            let path = try relativePath(url, in: root)
            if path == PluginStoreClient.receiptName { continue }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
            guard safePath(path), values.isSymbolicLink != true, seen.insert(path.lowercased()).inserted else {
                throw PluginStoreError("Unsafe file path in plugin: \(path).")
            }
            if values.isDirectory == true { continue }
            let attributes = try fm.attributesOfItem(atPath: url.path)
            guard values.isRegularFile == true, (values.fileSize ?? 0) <= 5_000_000,
                  ((attributes[.posixPermissions] as? Int ?? 0) & 0o111) == 0 else {
                throw PluginStoreError("Plugin files must be regular, non-executable files up to 5 MB: \(path).")
            }
            total += values.fileSize ?? 0
            result.append(url)
            guard result.count <= 200, total <= 20_000_000 else { throw PluginStoreError("Plugins are limited to 200 files and 20 MB.") }
        }
        if let enumerationError { throw enumerationError }
        return result.sorted { $0.path < $1.path }
    }

    @discardableResult static func validate(_ root: URL) throws -> [String: Any] {
        let files = try files(root)
        func json(_ name: String) throws -> [String: Any] {
            guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(name))) as? [String: Any] else {
                throw PluginStoreError("\(name) must contain a JSON object.")
            }
            return value
        }
        let manifest = try json("plugin.json"), metadata = try json("store.json")
        guard let id = manifest["id"] as? String, validID(id), id == root.lastPathComponent,
              let name = manifest["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PluginStoreError("plugin.json needs a name and an ID matching its folder.")
        }
        for key in ["description", "author", "version"] {
            guard let value = metadata[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PluginStoreError("store.json needs \(key).")
            }
        }
        guard validVersion(metadata["version"] as? String ?? ""), let tags = metadata["tags"] as? [String],
              tags.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }), let screenshots = metadata["screenshots"] as? [String] else {
            throw PluginStoreError("store.json needs a semantic version, tags array and screenshots array.")
        }
        if manifest["version"] != nil, manifest["version"] as? String != metadata["version"] as? String { throw PluginStoreError("plugin.json version must match store.json.") }
        let entry = manifest["entry"] as? String ?? "index.html"
        for key in ["entry", "symbol", "icon"] where manifest[key] != nil {
            guard let value = manifest[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PluginStoreError("\(key) must be a nonempty string.")
            }
        }
        if let order = manifest["order"] {
            guard let number = number(order), number.isFinite, number.rounded() == number,
                  number >= Double(Int32.min), number <= Double(Int32.max) else {
                throw PluginStoreError("order must be an integer between \(Int32.min) and \(Int32.max).")
            }
        }
        let paths = Set(try files.map { try relativePath($0, in: root) })
        for path in [entry] + screenshots + ((manifest["icon"] as? String).map({ [$0] }) ?? []) {
            guard safePath(path), paths.contains(path) else { throw PluginStoreError("Missing or unsafe plugin asset: \(path).") }
        }
        if let height = manifest["height"] {
            guard let number = number(height), (80...400).contains(number) else { throw PluginStoreError("height must be between 80 and 400.") }
        }
        if let settings = manifest["settings"] {
            guard let settings = settings as? [[String: Any]] else { throw PluginStoreError("settings must be an array of objects.") }
            var keys = Set<String>()
            for setting in settings {
                guard let key = setting["key"] as? String, !key.isEmpty, keys.insert(key).inserted,
                      let label = setting["label"] as? String, !label.isEmpty,
                      let type = setting["type"] as? String, ["toggle", "text", "secret", "textarea", "number", "select", "color"].contains(type) else {
                    throw PluginStoreError("Invalid or duplicate plugin setting.")
                }
                if type == "select", (setting["options"] as? [Any] ?? []).isEmpty { throw PluginStoreError("Select settings need options.") }
                if let options = setting["options"], !(options is NSNull) {
                    guard let values = options as? [String], Set(values).count == values.count else {
                        throw PluginStoreError("Setting options must be unique strings.")
                    }
                }
                if let help = setting["help"], !(help is String || help is NSNull) { throw PluginStoreError("Setting help must be text.") }
                for field in ["min", "max", "step"] {
                    if let value = setting[field], !(value is NSNull), number(value)?.isFinite != true {
                        throw PluginStoreError("Setting \(field) must be a finite number.")
                    }
                }
                if let min = setting["min"].flatMap(number), let max = setting["max"].flatMap(number), min > max {
                    throw PluginStoreError("Setting min must not exceed max.")
                }
                if let step = setting["step"].flatMap(number), step <= 0 { throw PluginStoreError("Setting step must be positive.") }
                if let value = setting["default"], !(value is NSNull || value is String || value is NSNumber) {
                    throw PluginStoreError("Setting defaults must be JSON scalars.")
                }
            }
        }
        for file in files where ["html", "css", "js", "mjs"].contains(file.pathExtension) {
            let code = try String(contentsOf: file, encoding: .utf8)
            if code.range(of: #"<(script|link)[^>]+(src|href)\s*=\s*["']\s*(https?:|//)|@import\s+(url\()?\s*['"]?\s*(https?:|//)"#, options: [.regularExpression, .caseInsensitive]) != nil {
                throw PluginStoreError("Bundle scripts and styles locally: \(file.lastPathComponent).")
            }
            if code.range(of: #"(html|body)\s*\{[^}]*background(-color)?\s*:\s*(#fff|white|rgb\(255)"#, options: [.regularExpression, .caseInsensitive]) != nil {
                throw PluginStoreError("The plugin page background must stay transparent.")
            }
        }
        return metadata
    }

    static func objectSHA(_ type: String, _ data: Data) -> String {
        var object = Data("\(type) \(data.count)\0".utf8)
        object.append(data)
        return Insecure.SHA1.hash(data: object).map { String(format: "%02x", $0) }.joined()
    }

    static func treeSHA(_ root: URL) throws -> String {
        let all = try files(root)
        func tree(_ directory: URL) throws -> String {
            var body = Data()
            let children = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])
                .filter { $0.lastPathComponent != PluginStoreClient.receiptName }
            let sorted = try children.map { url -> (URL, Bool) in (url, try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true) }
                .sorted { Array(($0.0.lastPathComponent + ($0.1 ? "/" : "")).utf8).lexicographicallyPrecedes(Array(($1.0.lastPathComponent + ($1.1 ? "/" : "")).utf8)) }
            for (url, isDirectory) in sorted {
                if isDirectory, !all.contains(where: { $0.path.hasPrefix(url.path + "/") }) { continue }
                let sha = try isDirectory ? tree(url) : objectSHA("blob", Data(contentsOf: url))
                body.append(Data("\(isDirectory ? "40000" : "100644") \(url.lastPathComponent)\0".utf8))
                for offset in stride(from: 0, to: sha.count, by: 2) {
                    let start = sha.index(sha.startIndex, offsetBy: offset)
                    body.append(UInt8(sha[start..<sha.index(start, offsetBy: 2)], radix: 16)!)
                }
            }
            return objectSHA("tree", body)
        }
        return try tree(root.resolvingSymlinksInPath())
    }
}
