import AppKit

/// Is Codex installed and signed in with ChatGPT? Powers Settings → ChatGPT & Codex and the notch's "connect" prompt.
enum CodexLink {
    enum State: Equatable {
        case notInstalled
        case signedOut
        case apiKey
        case ready(email: String?)
    }

    static func state() -> State {
        switch OpenAITranscriber.readAuth() {
        case .chatgpt: return .ready(email: email())
        case .apiKey: return .apiKey
        case nil: return cliPath() == nil ? .notInstalled : .signedOut
        }
    }

    /// The `codex` command from the user's login shell (bun/npm/brew installs live in different places).
    static func cliPath() -> String? {
        pathLock.lock()
        defer { pathLock.unlock() }
        if pathLoaded { return cachedPath }
        let shell = run("/bin/zsh", ["-lic", "command -v codex"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = [shell] + ["/opt/homebrew/bin/codex", "/usr/local/bin/codex",
                                     NSHomeDirectory() + "/.bun/bin/codex", NSHomeDirectory() + "/.local/bin/codex"]
        cachedPath = candidates.first { !$0.isEmpty && FileManager.default.isExecutableFile(atPath: $0) }
        pathLoaded = true
        return cachedPath
    }

    static func refresh() {
        pathLock.lock()
        defer { pathLock.unlock() }
        cachedPath = nil
        pathLoaded = false
    }
    private static let pathLock = NSLock()
    private static var cachedPath: String?
    private static var pathLoaded = false

    /// The ChatGPT email inside the id_token (a JWT) Codex stored.
    private static func email() -> String? {
        guard let data = try? Data(contentsOf: OpenAITranscriber.authURL),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let token = (json["tokens"] as? [String: Any])?["id_token"] as? String else { return nil }
        let parts = token.split(separator: ".")
        guard parts.count > 1 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let body = Data(base64Encoded: payload),
              let claims = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return nil }
        return claims["email"] as? String
    }

    /// The install command that fits this Mac (bun → Homebrew → npm).
    static var installCommand: String {
        let has = { (tool: String) in !run("/bin/zsh", ["-lic", "command -v \(tool)"]).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if has("bun") { return "bun add -g @openai/codex" }
        if has("brew") { return "brew install codex" }
        return "npm install -g @openai/codex"
    }

    static func install() async -> String? {
        await Task.detached(priority: .userInitiated) { runInTerminal(installCommand + " && codex login") }.value
    }
    static func signIn() async -> String? {
        await Task.detached(priority: .userInitiated) { runInTerminal("codex login") }.value
    }

    /// A real round-trip through the user's subscription: (ok, seconds, message).
    static func test() async -> (Bool, Double, String) {
        let start = Date()
        do {
            let text = try await AIBrain.complete(provider: "codex", model: "gpt-6-luna", effort: "none",
                                                  prompt: "Reply with exactly the word: ready") { _ in }
            return (true, Date().timeIntervalSince(start), text)
        } catch {
            return (false, Date().timeIntervalSince(start), error.localizedDescription)
        }
    }

    private static func runInTerminal(_ command: String) -> String? {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"Terminal\"\nactivate\ndo script \"\(escaped)\"\nend tell"
        guard let appleScript = NSAppleScript(source: script) else { return "Couldn’t prepare the Terminal command. Try again." }
        var error: NSDictionary?
        appleScript.executeAndReturnError(&error)
        return error?["NSAppleScriptErrorMessage"] as? String ?? error?.description
    }

    @discardableResult
    private static func run(_ path: String, _ args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
