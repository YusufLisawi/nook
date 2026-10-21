import Foundation

private struct PublisherTestFailure: Error { let message: String }
private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw PublisherTestFailure(message: message) }
}

/// A fake gh runner: these tests cannot reach GitHub or use local credentials.
private final class GitHubPublisherMock {
    var calls: [[String]] = []
    var bodies: [(String, [String: Any])] = []
    var account = "contributor"
    var parent = PluginStoreClient.repository
    var failPullRequest = false

    func run(_ arguments: [String]) throws -> Data {
        calls.append(arguments)
        let upstream = PluginStoreClient.repository
        guard arguments.first == "api" else {
            if arguments.prefix(2) == ["repo", "fork"] { return Data() }
            guard arguments.prefix(2) == ["pr", "create"] else { throw PublisherTestFailure(message: "Unexpected gh invocation") }
            let bodyIndex = arguments.firstIndex(of: "--body-file")!
            let body = try String(contentsOfFile: arguments[bodyIndex + 1], encoding: .utf8)
            try expect(body.contains("Word Count") && body.contains("1.0.0"), "PR body preserves plugin details")
            try expect(arguments.contains("main") && arguments.contains(upstream), "PR targets the upstream main branch")
            if failPullRequest { throw PluginStoreError("Synthetic PR failure") }
            return Data("https://example.invalid/pull/1\n".utf8)
        }
        let endpoint = arguments[1]
        if let inputIndex = arguments.firstIndex(of: "--input") {
            let body = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: arguments[inputIndex + 1]))) as! [String: Any]
            bodies.append((endpoint, body))
            if endpoint.hasSuffix("/git/blobs") {
                try expect(body["encoding"] as? String == "base64", "File upload uses base64")
                return try json(["sha": "blob-sha"])
            }
            if endpoint.hasSuffix("/git/trees") { return try json(["sha": "tree-sha"]) }
            if endpoint.hasSuffix("/git/commits") { return try json(["sha": "commit-sha"]) }
            if endpoint.hasSuffix("/git/refs") { return try json(["ref": body["ref"]!]) }
            throw PublisherTestFailure(message: "Unexpected write endpoint: \(endpoint)")
        }
        if endpoint == "user" { return try json(["login": account]) }
        if endpoint == "repos/\(account)/nook-plugins" { return try json(["parent": ["full_name": parent]]) }
        if endpoint == "repos/\(upstream)/git/ref/heads/main" { return try json(["object": ["sha": "base-commit"]]) }
        if endpoint == "repos/\(upstream)/git/commits/base-commit" { return try json(["tree": ["sha": "base-tree"]]) }
        throw PublisherTestFailure(message: "Unexpected read endpoint: \(endpoint)")
    }

    private func json(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
}

@main private struct StorePublisherTests {
    static func main() throws {
        let source = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("plugins/word-count")
        let preview = GitHubPublisherMock()
        try PluginStorePublisher.publish(source, confirmed: false, runGH: preview.run)
        try expect(preview.calls.isEmpty, "Preview never runs gh, including read-only commands")

        let contribution = GitHubPublisherMock()
        try PluginStorePublisher.publish(source, confirmed: true, runGH: contribution.run)
        try expect(contribution.calls.contains { $0.prefix(2) == ["repo", "fork"] }, "Contributors fork first")
        try expect(contribution.calls.last?.prefix(2) == ["pr", "create"], "Opens a PR after creating a contribution branch")
        let rootTree = contribution.bodies.first { $0.1["base_tree"] != nil }!.1
        let replacements = rootTree["tree"] as! [[String: String]]
        try expect(rootTree["base_tree"] as? String == "base-tree", "Retains unrelated plugins from upstream")
        try expect(replacements.count == 1 && replacements[0]["path"] == "plugins/word-count" && replacements[0]["type"] == "tree", "Replaces only the submitted plugin subtree")
        let commit = contribution.bodies.first { $0.0.hasSuffix("/git/commits") }!.1
        try expect(commit["parents"] as? [String] == ["base-commit"], "Branches from upstream main")
        let reference = contribution.bodies.first { $0.0.hasSuffix("/git/refs") }!.1["ref"] as! String
        try expect(reference.hasPrefix("refs/heads/plugin/word-count-"), "Writes a separate contribution branch")
        try expect(!contribution.calls.contains { $0.contains("merge") || $0.contains("push") }, "Never merges or pushes a local checkout")

        let owner = GitHubPublisherMock()
        owner.account = "YusufLisawi"
        try PluginStorePublisher.publish(source, confirmed: true, runGH: owner.run)
        try expect(!owner.calls.contains { $0.prefix(2) == ["repo", "fork"] }, "Repository owner needs no fork")

        let collision = GitHubPublisherMock()
        collision.parent = "someone-else/nook-plugins"
        do {
            try PluginStorePublisher.publish(source, confirmed: true, runGH: collision.run)
            throw PublisherTestFailure(message: "Unrelated repository should reject publishing")
        } catch is PluginStoreError { /* Expected. */ }
        try expect(collision.bodies.isEmpty, "An unrelated fork receives no uploads or branches")

        let failure = GitHubPublisherMock()
        failure.failPullRequest = true
        do {
            try PluginStorePublisher.publish(source, confirmed: true, runGH: failure.run)
            throw PublisherTestFailure(message: "PR failure should propagate")
        } catch is PluginStoreError { /* Expected. */ }
        print("✓ Publisher: no-op preview, contributor fork, owner branch, subtree replacement, collision and PR errors (all gh calls mocked)")
    }
}
