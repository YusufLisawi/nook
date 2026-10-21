import AppKit

/// Installs the `nook` CLI (→ ~/.local/bin/nook) and the Nook agent skill (→ ~/.agents/skills/nook, linked into
/// Claude Code, Codex and any other agent that has a skills folder). Runs once per app version, or from Settings.
enum ToolsInstaller {
    static let autoKey = "toolsAutoInstall"
    private static let versionKey = "toolsInstalledVersion"
    private static let fm = FileManager.default
    private static let home = fm.homeDirectoryForCurrentUser

    static var cliSource: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/nook-cli") }
    static var skillSource: URL? { Bundle.main.resourceURL?.appendingPathComponent("skill/nook") }
    static var binDir: URL { home.appendingPathComponent(".local/bin") }
    static var cliLink: URL { binDir.appendingPathComponent("nook") }
    static var skillHome: URL { home.appendingPathComponent(".agents/skills/nook") }

    /// Claude Code and Codex always get the skill; other agents only if they're installed.
    static var agents: [(name: String, dir: URL, always: Bool)] {
        [("Claude Code", ".claude", true), ("Codex", ".codex", true), ("Cursor", ".cursor", false),
         ("Windsurf", ".windsurf", false), ("Gemini", ".gemini", false), ("Factory", ".factory", false)]
            .map { ($0.0, home.appendingPathComponent($0.1), $0.2) }
    }

    static var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    static func installIfNeeded() {
        UserDefaults.standard.register(defaults: [autoKey: true])
        guard UserDefaults.standard.bool(forKey: autoKey),
              UserDefaults.standard.string(forKey: versionKey) != appVersion else { return }
        DispatchQueue.global(qos: .utility).async { install() }
    }

    @discardableResult
    static func install() -> [String] {
        var log: [String] = []
        // CLI: a symlink into the app, so it updates with the app.
        do {
            try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
            if (try? fm.destinationOfSymbolicLink(atPath: cliLink.path)) != nil || fm.fileExists(atPath: cliLink.path) {
                try fm.removeItem(at: cliLink)
            }
            try fm.createSymbolicLink(at: cliLink, withDestinationURL: cliSource)
            log.append("✓ nook CLI → \(cliLink.path)")
        } catch {
            log.append("✗ CLI: \(error.localizedDescription)")
        }
        // Skill: one real copy in ~/.agents/skills, symlinked into each agent.
        if let source = skillSource, fm.fileExists(atPath: source.path) {
            do {
                try fm.createDirectory(at: skillHome.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: skillHome.path) || (try? fm.destinationOfSymbolicLink(atPath: skillHome.path)) != nil {
                    try fm.removeItem(at: skillHome)
                }
                try fm.copyItem(at: source, to: skillHome)
                for agent in agents where agent.always || fm.fileExists(atPath: agent.dir.path) {
                    let skills = agent.dir.appendingPathComponent("skills")
                    try fm.createDirectory(at: skills, withIntermediateDirectories: true)
                    let link = skills.appendingPathComponent("nook")
                    if (try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil || fm.fileExists(atPath: link.path) {
                        try fm.removeItem(at: link)
                    }
                    try fm.createSymbolicLink(at: link, withDestinationURL: skillHome)
                    log.append("✓ skill → \(agent.name)")
                }
            } catch {
                log.append("✗ skill: \(error.localizedDescription)")
            }
        }
        UserDefaults.standard.set(appVersion, forKey: versionKey)
        return log
    }

    // MARK: Status

    static var cliInstalled: Bool { (try? fm.destinationOfSymbolicLink(atPath: cliLink.path)) == cliSource.path }

    static var cliOnPath: Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lic", "echo $PATH"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return out.split(separator: ":").contains { $0.trimmingCharacters(in: .whitespacesAndNewlines) == binDir.path }
    }

    static func skillInstalled(in agent: URL) -> Bool {
        fm.fileExists(atPath: agent.appendingPathComponent("skills/nook/SKILL.md").path)
    }

    /// Adds ~/.local/bin to PATH in ~/.zprofile (only when the user clicks the button).
    static func addToPath() {
        let profile = home.appendingPathComponent(".zprofile")
        let line = "\n# Added by Nook: the `nook` command\nexport PATH=\"$HOME/.local/bin:$PATH\"\n"
        let current = (try? String(contentsOf: profile, encoding: .utf8)) ?? ""
        guard !current.contains("$HOME/.local/bin") else { return }
        try? (current + line).write(to: profile, atomically: true, encoding: .utf8)
    }
}
