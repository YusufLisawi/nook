import Foundation

/// Nothing remote is changed until the caller explicitly supplies --yes.
enum PluginStorePublisher {
    static func publish(_ source: URL, confirmed: Bool, runGH: ([String]) throws -> Data = gh) throws {
        let fm = FileManager.default
        let metadata = try PluginStorePackage.validate(source)
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: source.appendingPathComponent("plugin.json"))) as! [String: Any]
        let id = manifest["id"] as! String
        let version = metadata["version"] as! String
        let files = try PluginStorePackage.files(source)
        let snapshot = try files.map { url in (try PluginStorePackage.relativePath(url, in: source), try Data(contentsOf: url), FileManager.default.isExecutableFile(atPath: url.path)) }
        print("Publish plan for \(id) \(version):")
        print("  1. Use your authenticated gh account; fork \(PluginStoreClient.repository) if needed.")
        print("  2. Create a new contribution branch based on the Store's current main.")
        print("  3. Upload these \(snapshot.count) files under plugins/\(id)/ (replacing that folder):")
        snapshot.forEach { print("     \($0.0)") }
        print("  4. Open a pull request for maintainer review. Nothing is merged or published automatically.")
        guard confirmed else {
            print("No remote changes made. Review the files, then rerun: nook publish <path> --yes")
            return
        }

        let temporary = fm.temporaryDirectory.appendingPathComponent("nook-publish-\(UUID().uuidString)")
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temporary) }
        // Revalidate an immutable local snapshot before uploading anything.
        let package = temporary.appendingPathComponent(id)
        for (path, data, executable) in snapshot {
            let file = package.appendingPathComponent(path)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file)
            try fm.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: file.path)
        }
        try PluginStorePackage.validate(package)

        func api(_ endpoint: String, body: [String: Any]? = nil) throws -> [String: Any] {
            var arguments = ["api", endpoint]
            if let body {
                let payload = temporary.appendingPathComponent("request.json")
                try JSONSerialization.data(withJSONObject: body).write(to: payload, options: .atomic)
                arguments += ["--method", "POST", "--input", payload.path]
            }
            let data = try runGH(arguments)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw PluginStoreError("gh returned an invalid response.") }
            return object
        }
        func string(_ object: [String: Any], _ key: String) throws -> String {
            guard let value = object[key] as? String, !value.isEmpty else { throw PluginStoreError("GitHub response is missing \(key).") }
            return value
        }
        let upstream = PluginStoreClient.repository
        let account = try string(api("user"), "login")
        let owner = String(upstream.split(separator: "/")[0])
        let destination = "\(account)/nook-plugins"
        if account.caseInsensitiveCompare(owner) != .orderedSame {
            _ = try runGH(["repo", "fork", upstream, "--clone=false", "--remote=false"])
            let fork = try api("repos/\(destination)")
            guard (fork["parent"] as? [String: Any])?["full_name"] as? String == upstream else {
                throw PluginStoreError("\(destination) is not a fork of \(upstream). No contribution branch was created.")
            }
        }
        let reference = try api("repos/\(upstream)/git/ref/heads/main")
        guard let object = reference["object"] as? [String: Any] else { throw PluginStoreError("The Store has no main branch yet.") }
        let base = try string(object, "sha")
        let baseCommit = try api("repos/\(upstream)/git/commits/\(base)")
        guard let baseTree = baseCommit["tree"] as? [String: Any] else { throw PluginStoreError("Couldn't read the Store's base tree.") }
        let baseTreeSHA = try string(baseTree, "sha")
        var blobs: [[String: Any]] = []
        for (path, data, executable) in snapshot {
            let blob = try api("repos/\(destination)/git/blobs", body: ["content": data.base64EncodedString(), "encoding": "base64"])
            blobs.append(["path": path, "mode": executable ? "100755" : "100644", "type": "blob", "sha": try string(blob, "sha")])
        }
        let pluginTree = try api("repos/\(destination)/git/trees", body: ["tree": blobs])
        let tree = try api("repos/\(destination)/git/trees", body: ["base_tree": baseTreeSHA, "tree": [
            ["path": "plugins/\(id)", "mode": "040000", "type": "tree", "sha": try string(pluginTree, "sha")]
        ]])
        let commit = try api("repos/\(destination)/git/commits", body: ["message": "Add/update \(id) \(version)", "tree": try string(tree, "sha"), "parents": [base]])
        let branch = "plugin/\(id)-\(UUID().uuidString.lowercased().prefix(8))"
        _ = try api("repos/\(destination)/git/refs", body: ["ref": "refs/heads/\(branch)", "sha": try string(commit, "sha")])
        let body = temporary.appendingPathComponent("pr.md")
        try """
        Adds/updates **\(manifest["name"] as? String ?? id)** (\(id)) to \(version).

        \(metadata["description"] as? String ?? "")

        Author: \(metadata["author"] as? String ?? "")

        Validated locally with `nook validate` and Store package checks. Please review source, permissions, metadata, and keyboard behavior before merging.
        """.write(to: body, atomically: true, encoding: .utf8)
        print("Created \(destination):\(branch). Opening the contribution PR…")
        let result = try runGH(["pr", "create", "--repo", upstream, "--base", "main", "--head", "\(account):\(branch)",
            "--title", "Add/update \(id) \(version)", "--body-file", body.path])
        print(String(decoding: result, as: UTF8.self))
    }

    private static func gh(_ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["gh"] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GH_PROMPT_DISABLED"] = "1"
        process.environment = environment
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        // Drain stderr concurrently so a verbose gh failure cannot block on a full pipe.
        let group = DispatchGroup()
        let stderr = StoreProcessOutput()
        group.enter()
        DispatchQueue.global().async { stderr.data = errors.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        group.wait()
        guard process.terminationStatus == 0 else {
            throw PluginStoreError("gh failed: \(String(decoding: stderr.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return data
    }
}

private final class StoreProcessOutput: @unchecked Sendable { var data = Data() }
