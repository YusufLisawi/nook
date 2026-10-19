// nook — CLI for Nook, the notch app. Ships inside Nook.app (Contents/MacOS/nook-cli) and is linked to ~/.local/bin/nook.
import AppKit
import Foundation

let fm = FileManager.default
let home = fm.homeDirectoryForCurrentUser
let support = home.appendingPathComponent("Library/Application Support/Nook")
let userPlugins = support.appendingPathComponent("Plugins")
let dataDir = support.appendingPathComponent("Data")
let logFile = home.appendingPathComponent("Library/Logs/Nook/plugins.log")
let maxHeight = 400.0

/// Nook.app/Contents/Resources (follows the ~/.local/bin symlink); NOOK_RESOURCES overrides for development.
let resources: URL = {
    if let env = ProcessInfo.processInfo.environment["NOOK_RESOURCES"] { return URL(fileURLWithPath: env) }
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let fromBundle = exe.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources")
    if fm.fileExists(atPath: fromBundle.appendingPathComponent("Plugins").path) { return fromBundle }
    return URL(fileURLWithPath: "/Applications/Nook.app/Contents/Resources")
}()
let bundledPlugins = resources.appendingPathComponent("Plugins")

var args = Array(CommandLine.arguments.dropFirst())
let command = args.isEmpty ? "help" : args.removeFirst()
func flag(_ name: String) -> String? {
    guard let i = args.firstIndex(of: "--\(name)"), i + 1 < args.count else { return nil }
    return args[i + 1]
}
func has(_ name: String) -> Bool { args.contains("--\(name)") || args.contains("-\(name)") }
var positional: [String] {
    var out: [String] = []
    var skip = false
    for a in args {
        if skip { skip = false; continue }
        if a.hasPrefix("--") { skip = !["--json"].contains(a); continue }
        if a.hasPrefix("-") { continue }
        out.append(a)
    }
    return out
}

/// Flush buffered output before leaving — otherwise piped/captured output can be lost.
func quit(_ code: Int32) -> Never {
    fflush(stdout)
    exit(code)
}

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data("✗ \(message)\n".utf8))
    quit(1)
}

func readJSON(_ url: URL) -> Any? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONSerialization.jsonObject(with: data)
}

func printJSON(_ value: Any) {
    let data = (try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])) ?? Data("null".utf8)
    print(String(decoding: data, as: UTF8.self))
}

struct Plugin {
    var manifest: [String: Any]
    var dir: URL
    var source: String
    var id: String { manifest["id"] as? String ?? dir.lastPathComponent }
    var name: String { manifest["name"] as? String ?? id }
    var order: Int { manifest["order"] as? Int ?? 100 }
}

func plugins() -> [Plugin] {
    var byID: [String: Plugin] = [:]
    for (root, source) in [(bundledPlugins, "bundled"), (userPlugins, "user")] {
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for dir in dirs {
            let file = dir.appendingPathComponent("plugin.json")
            guard fm.fileExists(atPath: file.path) else { continue }
            guard let m = readJSON(file) as? [String: Any] else {
                byID[dir.lastPathComponent] = Plugin(manifest: ["id": dir.lastPathComponent, "name": "⚠ bad plugin.json"], dir: dir, source: source)
                continue
            }
            let id = m["id"] as? String ?? dir.lastPathComponent
            byID[id] = Plugin(manifest: m, dir: dir, source: byID[id] != nil ? "user (overrides bundled)" : source)
        }
    }
    return byID.values.sorted { ($0.order, $0.id) < ($1.order, $1.id) }
}

func find(_ idOrPath: String?) -> Plugin {
    guard let idOrPath else { die("Give a plugin id or folder path") }
    let url = URL(fileURLWithPath: (idOrPath as NSString).expandingTildeInPath)
    if let m = readJSON(url.appendingPathComponent("plugin.json")) as? [String: Any] { return Plugin(manifest: m, dir: url, source: "path") }
    guard let plugin = plugins().first(where: { $0.id == idOrPath }) else { die("No plugin \"\(idOrPath)\". Try: nook list") }
    return plugin
}

func text(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

func matches(_ s: String, _ pattern: String) -> Bool { s.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil }

func validate(_ p: Plugin) -> (errors: [String], warnings: [String]) {
    var errors: [String] = [], warnings: [String] = []
    guard let m = readJSON(p.dir.appendingPathComponent("plugin.json")) as? [String: Any] else { return (["plugin.json is not valid JSON"], []) }
    for key in ["id", "name"] where (m[key] as? String ?? "").isEmpty { errors.append("plugin.json needs \"\(key)\"") }
    if let id = m["id"] as? String {
        if !matches(id, "^[a-z0-9][a-z0-9-]*$") { errors.append("id \"\(id)\" must be lowercase letters, digits and dashes") }
        if id != p.dir.lastPathComponent { warnings.append("folder name \"\(p.dir.lastPathComponent)\" differs from id \"\(id)\"") }
    }
    let entry = m["entry"] as? String ?? "index.html"
    if !fm.fileExists(atPath: p.dir.appendingPathComponent(entry).path) { errors.append("entry file \"\(entry)\" is missing") }
    if let h = m["height"] { if let n = h as? Double, n >= 80, n <= maxHeight {} else { errors.append("height must be a number between 80 and \(Int(maxHeight))") } }
    if m["symbol"] == nil { warnings.append("no \"symbol\" — the dock shows a puzzle piece. Pick an SF Symbol (e.g. \"sparkles\")") }
    if let icon = m["icon"] as? String, !fm.fileExists(atPath: p.dir.appendingPathComponent(icon).path) { errors.append("icon \"\(icon)\" is missing") }

    let types = ["toggle", "text", "secret", "textarea", "number", "select", "color"]
    var keys = Set<String>()
    if let settings = m["settings"] {
        if let list = settings as? [[String: Any]] {
            for (i, s) in list.enumerated() {
                let key = s["key"] as? String ?? ""
                let label = "settings[\(i)]\(key.isEmpty ? "" : " (\(key))")"
                if key.isEmpty || (s["label"] as? String ?? "").isEmpty { errors.append("\(label) needs \"key\" and \"label\"") }
                if !types.contains(s["type"] as? String ?? "") { errors.append("\(label) type must be one of \(types.joined(separator: ", "))") }
                if s["type"] as? String == "select", (s["options"] as? [Any] ?? []).isEmpty { errors.append("\(label) select needs \"options\"") }
                if keys.contains(key) { errors.append("\(label) duplicate key") }
                keys.insert(key)
            }
        } else {
            errors.append("settings must be an array of objects")
        }
    }

    let files = ((try? fm.contentsOfDirectory(atPath: p.dir.path)) ?? []).filter { matches($0, "\\.(html|css|js|mjs)$") }
    var allCode = ""
    var size = 0
    for f in files {
        let url = p.dir.appendingPathComponent(f)
        let s = text(url)
        allCode += s
        size += (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        if matches(s, "<(script|link)[^>]+(src|href)=[\"']https?:") || matches(s, "@import\\s+(url\\()?[\"']?https?:") {
            errors.append("\(f): loads code/styles from the network — bundle it in the folder (plugins must work offline)")
        }
        if matches(s, "\\bfetch\\(\\s*[\"'`]https?:") { warnings.append("\(f): uses fetch() for http — use nook.fetch (no CORS limits)") }
        if matches(s, "(html|body)\\s*\\{[^}]*background(-color)?\\s*:\\s*(#fff|white|rgb\\(255)") { errors.append("\(f): page background must stay transparent (the notch is black)") }
        let rules = s.components(separatedBy: "}")
        if rules.contains(where: { matches($0, "border-left\\s*:\\s*[3-9]px\\s+solid\\s+(?!transparent)") && !matches($0, "width\\s*:\\s*0") }) {
            warnings.append("\(f): thick left border — Nook style avoids coloured edge stripes; tint the background instead")
        }
        if s.contains("localStorage.") { warnings.append("\(f): localStorage works, but nook.storage survives reinstalls and is readable with `nook storage`") }
    }
    if !keys.isEmpty, !matches(allCode, "nook\\.settings\\.get|nook\\.on\\(\\s*['\"]settings") {
        warnings.append("declares settings but never reads them (nook.settings.get / nook.on('settings'))")
    }
    if size > 1_500_000 { warnings.append(String(format: "code is %.1f MB — keep plugins light, the notch should open instantly", Double(size) / 1e6)) }
    return (errors, warnings)
}

func open(_ url: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = ["-g", url]
    try? p.run()
    p.waitUntilExit()
}

func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s + " " : s + String(repeating: " ", count: n - s.count) }

let help = """
nook — build and drive Nook plugins (no app rebuild needed)

  nook list [--json]              all plugins (bundled + yours), in dock order
  nook new <id> [--name N] [--symbol S] [--height H] [--order O]
                                  scaffold a plugin in your Plugins folder (live immediately)
  nook validate [id|path]         check a plugin (or all) against the rules
  nook eject <id>                 copy a bundled plugin into your folder so you can change it
  nook open <id> | toggle <id>    show a tab in the notch under the mouse
  nook close | reload | settings  close notches · reload all plugins · open Settings
  nook logs [id] [-f]             plugin console.log / errors (-f to follow)
  nook storage <id> [key]         read a plugin's saved data
  nook prefs <id>                 a plugin's settings: declared options + current values
  nook path [id]                  where plugins live (or one plugin's folder)
  nook api                        the window.nook bridge reference
  nook guide                      UI guidelines + patterns (the notch vibe)
  nook limits                     what plugins can and can't do
  nook version
"""

switch command {
case "help", "-h", "--help":
    print(help)

case "version", "--version":
    let info = NSDictionary(contentsOf: resources.deletingLastPathComponent().appendingPathComponent("Info.plist"))
    print("nook \(info?["CFBundleShortVersionString"] as? String ?? "dev")")

case "list":
    let list = plugins()
    if has("json") {
        printJSON(list.map { p -> [String: Any] in var m = p.manifest; m["dir"] = p.dir.path; m["source"] = p.source; return m })
    } else {
        for p in list {
            print("\(String(repeating: " ", count: max(0, 3 - String(p.order).count)))\(p.order)  \(pad(p.id, 16))\(pad(p.name, 16))\(pad(p.manifest["symbol"] as? String ?? "", 34))\(p.source)")
        }
    }

case "path":
    print(positional.first.map { find($0).dir.path } ?? userPlugins.path)

case "new":
    guard let id = positional.first else { die("Usage: nook new <id> [--name N] [--symbol S] [--height H]") }
    if !matches(id, "^[a-z0-9][a-z0-9-]*$") { die("id must be lowercase letters, digits and dashes") }
    let dir = userPlugins.appendingPathComponent(id)
    if fm.fileExists(atPath: dir.path) { die("\(dir.path) already exists") }
    if plugins().contains(where: { $0.id == id }) { die("id \"\(id)\" is taken (nook list)") }
    let defaultName = id.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    let vars = ["__ID__": id, "__NAME__": flag("name") ?? defaultName, "__SYMBOL__": flag("symbol") ?? "sparkles",
                "__HEIGHT__": flag("height") ?? "210", "__ORDER__": flag("order") ?? "100"]
    let template = resources.appendingPathComponent("template")
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    for f in (try? fm.contentsOfDirectory(atPath: template.path)) ?? [] {
        var s = text(template.appendingPathComponent(f))
        for (k, v) in vars { s = s.replacingOccurrences(of: k, with: v) }
        try? s.write(to: dir.appendingPathComponent(f), atomically: true, encoding: .utf8)
    }
    print("✓ Created \(dir.path)\n  It's live in the notch now. Edit main.js / index.html and it reloads on save.\n  nook open \(id)   ·   nook logs \(id) -f   ·   nook validate \(id)")

case "validate":
    var targets: [Plugin] = [] // (written out: the one-line Optional.map form came out empty under -O)
    if let id = positional.first { targets.append(find(id)) } else { targets = plugins() }
    var failed = 0
    for p in targets {
        let r = validate(p)
        print("\(r.errors.isEmpty ? (r.warnings.isEmpty ? "✓" : "!") : "✗") \(p.id)  (\(p.dir.path))")
        r.errors.forEach { print("    error: \($0)") }
        r.warnings.forEach { print("    warn:  \($0)") }
        if !r.errors.isEmpty { failed += 1 }
    }
    quit(failed > 0 ? 1 : 0)

case "eject":
    let p = find(positional.first)
    let dest = userPlugins.appendingPathComponent(p.id)
    if fm.fileExists(atPath: dest.path) { die("\(dest.path) already exists — that's your copy") }
    try? fm.createDirectory(at: userPlugins, withIntermediateDirectories: true)
    do { try fm.copyItem(at: p.dir, to: dest) } catch { die("Couldn't copy: \(error.localizedDescription)") }
    print("✓ Copied to \(dest.path). Your copy now overrides the bundled one.")

case "open", "toggle":
    guard let id = positional.first else { die("Usage: nook \(command) <id>") }
    open("nook://\(command)/\(id)")

case "close", "reload", "settings":
    open("nook://\(command)")

case "logs":
    guard fm.fileExists(atPath: logFile.path) else { print("No plugin logs yet."); quit(0) }
    let id = positional.first
    if args.contains("-f") {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "tail -n 30 -f \"\(logFile.path)\"" + (id.map { " | grep --line-buffered -F '[\($0)]'" } ?? "")]
        try? p.run()
        p.waitUntilExit()
    } else {
        let lines = text(logFile).split(separator: "\n").filter { id == nil || $0.contains("[\(id!)]") }
        print(lines.suffix(50).joined(separator: "\n").isEmpty ? "No logs for that plugin." : lines.suffix(50).joined(separator: "\n"))
    }

case "storage":
    guard let id = positional.first else { die("Usage: nook storage <id> [key]") }
    let data = readJSON(dataDir.appendingPathComponent("\(id).json")) as? [String: Any] ?? [:]
    printJSON(positional.count > 1 ? data[positional[1]] ?? NSNull() : data)

case "prefs":
    let p = find(positional.first)
    let saved = readJSON(dataDir.appendingPathComponent("\(p.id).settings.json")) as? [String: Any] ?? [:]
    let declared = p.manifest["settings"] as? [[String: Any]] ?? []
    if declared.isEmpty { print("\(p.id) declares no settings") }
    for s in declared {
        let key = s["key"] as? String ?? ""
        let json = { (v: Any?) -> String in
            guard let v, let d = try? JSONSerialization.data(withJSONObject: v, options: .fragmentsAllowed) else { return "null" }
            return String(decoding: d, as: UTF8.self)
        }
        let value = saved[key] != nil ? json(saved[key]) : json(s["default"]) + " (default)"
        print("\(pad(key, 18))\(pad(value, 28))\(pad(s["type"] as? String ?? "", 9))\(s["label"] as? String ?? "")")
    }

case "api", "guide", "limits":
    let file = ["api": "PLUGINS.md", "guide": "docs/UI-GUIDELINES.md", "limits": "docs/LIMITS.md"][command]!
    let s = text(resources.appendingPathComponent(file))
    if s.isEmpty { die("Docs not found in \(resources.path)") }
    print(s)

default:
    die("Unknown command \"\(command)\". Run: nook help")
}
