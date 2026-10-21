import CoreFoundation
import Foundation

struct PluginEngineError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Shared by discovery, the host, Store validation and the CLI. No plugin code runs while parsing.
struct PluginManifestV2 {
    struct Native {
        let command: String?
        let run: [String]?
        let background: Bool
    }
    static let permissions: Set<String> = ["files", "clipboard", "accessibility", "microphone", "network", "shell", "ai", "background", "hotkeys", "notifications", "launcher", "windows", "secrets"]
    static let contributionNames: Set<String> = ["hotkeys", "launcherItems", "answerProviders", "searchProviders", "settings", "menuBar", "notchActivity", "urlHandlers", "backgroundJobs"]
    let id: String
    let name: String
    let directory: URL
    let apiVersion: Int
    let requested: Set<String>
    let native: Native?
    let contributes: [String: [[String: Any]]]

    init(directory: URL) throws {
        let data = try Data(contentsOf: directory.appendingPathComponent("plugin.json"))
        guard data.count <= 1_000_000,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw PluginEngineError("Invalid plugin.json") }
        try self.init(json: json, directory: directory)
    }

    init(json: [String: Any], directory: URL) throws {
        guard let id = json["id"] as? String, id.range(of: "^[a-z0-9][a-z0-9-]{0,79}\\z", options: .regularExpression) != nil,
              let name = json["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 160 else { throw PluginEngineError("A plugin needs a valid id and name.") }
        self.id = id; self.name = name; self.directory = directory
        if let version = json["apiVersion"] {
            guard let n = version as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), [1, 2].contains(n.intValue), n.doubleValue == Double(n.intValue) else { throw PluginEngineError("apiVersion must be 1 or 2.") }
            apiVersion = n.intValue
        } else { apiVersion = 1 }
        if apiVersion == 1 {
            guard json["native"] == nil, json["contributes"] == nil else { throw PluginEngineError("native and contributes require apiVersion: 2.") }
            requested = []; native = nil; contributes = [:]; return
        }
        let entry = json["entry"] as? String ?? "index.html"
        guard Self.safeRelative(entry) else { throw PluginEngineError("entry must stay inside the plugin.") }
        var permissions = Set<String>()
        func readPermissions(_ value: Any?) throws {
            guard let value else { return }
            guard let list = value as? [String], Set(list).count == list.count, list.allSatisfy(Self.permissions.contains) else { throw PluginEngineError("Unknown or duplicate plugin permission.") }
            permissions.formUnion(list)
        }
        try readPermissions(json["permissions"])
        if let value = json["native"] {
            guard let spec = value as? [String: Any] else { throw PluginEngineError("native must be an object.") }
            guard spec["command"] == nil || spec["run"] == nil else { throw PluginEngineError("Choose native.command or native.run.") }
            try readPermissions(spec["permissions"])
            var command = spec["command"] as? String
            let run = spec["run"] as? [String] ?? (spec["command"] as? [String: Any])?["run"] as? [String]
            if command != nil, run != nil { throw PluginEngineError("Choose native.command or native.run.") }
            if let c = command {
                guard Self.safeRelative(c) else { throw PluginEngineError("native.command must be a relative path inside the plugin.") }
                command = c
            } else {
                guard let run, !run.isEmpty, run.count <= 64, run.allSatisfy({ !$0.isEmpty && !$0.contains("\0") }),
                      ["node", "python3", "ruby", "swift", "bash", "sh"].contains(run[0]), run.count > 1,
                      Self.safeRelative(run[1]), !run[1].hasPrefix("-") else { throw PluginEngineError("native.run must be [interpreter, relative-script, arguments…].") }
            }
            if let b = spec["background"], !(b is NSNumber && CFGetTypeID(b as! NSNumber) == CFBooleanGetTypeID()) { throw PluginEngineError("native.background must be a boolean.") }
            native = Native(command: command, run: run, background: spec["background"] as? Bool ?? false)
            if native?.background == true, !permissions.contains("background") { throw PluginEngineError("A background helper must declare background permission.") }
        } else { native = nil }
        if (json["settings"] as? [[String: Any]] ?? []).contains(where: { $0["type"] as? String == "shortcut" }), !permissions.contains("hotkeys") { throw PluginEngineError("Shortcut settings require hotkeys permission.") }
        requested = permissions
        var contributions: [String: [[String: Any]]] = [:]
        if let value = json["contributes"] {
            guard let spec = value as? [String: Any], Set(spec.keys).isSubset(of: Self.contributionNames) else { throw PluginEngineError("Unknown contributes section.") }
            for (key, value) in spec {
                guard let items = value as? [[String: Any]], items.count <= 100 else { throw PluginEngineError("contributes.\(key) must be an array (at most 100).") }
                var ids = Set<String>()
                for item in items {
                    guard let id = item["id"] as? String, id.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,99}\\z", options: .regularExpression) != nil, ids.insert(id).inserted else { throw PluginEngineError("Contributions need unique ids (letters, digits, dot, underscore, dash).") }
                    let nonempty = { (key: String) in (item[key] as? String).map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false }
                    switch key {
                    case "hotkeys":
                        guard let code = item["keyCode"] as? NSNumber, CFGetTypeID(code) != CFBooleanGetTypeID(), code.doubleValue == Double(code.intValue), (0...127).contains(code.intValue),
                              let flags = item["modifiers"] as? NSNumber, CFGetTypeID(flags) != CFBooleanGetTypeID(), flags.doubleValue == Double(flags.uint64Value), flags.uint64Value & 0x1C0000 != 0 else { throw PluginEngineError("Hotkeys need keyCode (0–127) and Command/Control/Option CGEventFlags modifiers.") }
                    case "launcherItems": guard nonempty("title") else { throw PluginEngineError("Launcher items need a title.") }
                    case "searchProviders": guard nonempty("method"), nonempty("actionMethod"), json["native"] != nil else { throw PluginEngineError("Search providers need method, actionMethod and a native helper.") }
                    case "answerProviders": guard nonempty("prefix"), nonempty("method"), json["native"] != nil else { throw PluginEngineError("Answer providers need prefix, method and a native helper.") }
                    case "backgroundJobs":
                        guard let number = item["interval"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite, (1...86_400).contains(number.doubleValue) else { throw PluginEngineError("Background jobs need an interval from 1 to 86400 seconds.") }
                    default: break
                    }
                }
                contributions[key] = items
            }
            let requirements = ["hotkeys": "hotkeys", "launcherItems": "launcher", "answerProviders": "launcher", "searchProviders": "launcher", "backgroundJobs": "background"]
            for (section, permission) in requirements where !(contributions[section] ?? []).isEmpty && !permissions.contains(permission) { throw PluginEngineError("\(section) requires \(permission) permission.") }
        }
        contributes = contributions
    }

    static func safeRelative(_ path: String) -> Bool {
        !path.isEmpty && !path.contains("\\") && !path.contains(":") && !path.contains("\0") &&
        path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    func containedURL(_ path: String) throws -> URL {
        guard Self.safeRelative(path) else { throw PluginEngineError("Unsafe plugin path.") }
        let root = PluginPath.resolve(directory)
        let url = PluginPath.resolve(root.appendingPathComponent(path))
        guard url.path.hasPrefix(root.path + "/") else { throw PluginEngineError("Plugin path escapes its directory.") }
        return url
    }

    /// Prefer the running architecture, then a universal executable. Never invoke a shell to resolve a command.
    func executable() throws -> (URL, [String]) {
        guard let native else { throw PluginEngineError("This plugin has no helper.") }
        if let command = native.command {
            #if arch(arm64)
            let arch = "arm64"
            #else
            let arch = "x86_64"
            #endif
            let perArch = command.hasPrefix("bin/") ? "bin/\(arch)/" + command.dropFirst(4) : command
            let candidate = try containedURL(perArch)
            let url = FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : try containedURL(command)
            guard FileManager.default.isExecutableFile(atPath: url.path) else { throw PluginEngineError("Helper missing or not executable: \(command). Build the plugin first.") }
            return (url, [])
        }
        let run = native.run!
        _ = try containedURL(run[1])
        // An explicit allowlisted interpreter, not /usr/bin/env with plugin-controlled switches.
        let roots = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        guard let interpreter = roots.map({ URL(fileURLWithPath: $0).appendingPathComponent(run[0]) }).first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else { throw PluginEngineError("Install \(run[0]) to run this plugin.") }
        return (interpreter, Array(run.dropFirst()))
    }
}

enum PluginPath {
    /// Resolving the whole URL can leave symlink parents unresolved when its leaf doesn't exist.
    /// Walk existing ancestors first, so a not-yet-created write target cannot hide an escape.
    static func resolve(_ url: URL) -> URL {
        url.standardizedFileURL.pathComponents.dropFirst().reduce(URL(fileURLWithPath: "/")) {
            $0.appendingPathComponent($1).resolvingSymlinksInPath()
        }.standardizedFileURL
    }
}

struct PluginPermissionGrant: Codable {
    var permissions: Set<String>
    var native: Bool
    var fileScopes: [String]
    func allows(_ manifest: PluginManifestV2) -> Bool {
        manifest.requested.isSubset(of: permissions) && (manifest.native == nil || native)
    }
}

enum PluginCapabilityPolicy {
    /// Nil means the call is unknown, not unprivileged. Unknown v2 calls fail closed.
    static func required(_ method: String) -> Set<String>? {
        let method = method.hasPrefix("host.") ? String(method.dropFirst(5)) : method
        let family = method.split(separator: ".").first.map(String.init) ?? method
        switch family {
        case "native", "notch", "activity", "storage", "settings", "log", "keyboard", "features": return []
        case "actions": return ["launcher"]
        case "clipboard": return ["clipboard"]
        case "files": return ["files"]
        case "fetch", "network": return ["network"]
        case "shell": return ["shell"]
        case "ai": return ["ai"]
        case "notify", "notifications": return ["notifications"]
        case "selection", "accessibility": return ["accessibility"]
        case "hotkeys": return ["hotkeys"]
        case "secrets": return ["secrets"]
        case "windows": return ["windows"]
        case "launcher": return ["launcher"]
        case "jobs": return ["background"]
        case "open": return ["files"]
        default: return nil
        }
    }
    static func check(_ method: String, manifest: PluginManifestV2, grant: PluginPermissionGrant?) throws {
        guard manifest.apiVersion >= 2 else { return }
        guard let grant, grant.allows(manifest) else { throw PluginEngineError("Approve this plugin in Settings → Tabs & Plugins before using it.") }
        guard let needed = required(method) else { throw PluginEngineError("API v2 does not expose \(method). Use a helper for feature code.") }
        guard needed.isSubset(of: manifest.requested), needed.isSubset(of: grant.permissions) else { throw PluginEngineError("Permission denied: \(needed.sorted().joined(separator: ", ")).") }
    }
}

enum PluginFileScope {
    static func resolve(_ path: String, dataRoot: URL, scopes: [String]) throws -> URL {
        guard !path.isEmpty, !path.contains("\0") else { throw PluginEngineError("Expected a file path.") }
        let candidate = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : dataRoot.appendingPathComponent(path)).standardizedFileURL
        let roots = [dataRoot] + scopes.map { URL(fileURLWithPath: $0) }
        guard roots.contains(where: { $0.standardizedFileURL.path == "/" || candidate.path == $0.standardizedFileURL.path || candidate.path.hasPrefix($0.standardizedFileURL.path + "/") }) else { throw PluginEngineError("File is outside this plugin’s granted folders.") }
        let url = PluginPath.resolve(candidate)
        guard roots.contains(where: { root in
            let root = PluginPath.resolve(root).path
            return root == "/" || url.path == root || url.path.hasPrefix(root + "/")
        }) else { throw PluginEngineError("File is outside this plugin’s granted folders.") }
        return url
    }
}
