import AppKit
import Combine

@main enum LauncherHelper {
    static var subscription: AnyCancellable?
    static var history: [String: LauncherUsage] = [:]
    static func save() { PluginDefaults.standard.set(try? JSONEncoder().encode(history), forKey: "launcher.history") }
    static func registerShortcut() {
        PluginRuntime.host("hotkeys.unregister", ["id": "open"])
        let raw = PluginDefaults.standard.string(forKey: "shortcut.open") ?? "{}"
        guard let key = try? JSONDecoder().decode(TabHotkey.self, from: Data(raw.utf8)) else { return }
        PluginRuntime.host("hotkeys.register", ["id": "open", "title": "Open Launcher", "keyCode": key.keyCode, "modifiers": key.modifiers, "display": key.display]) { _, error in
            if let error { PluginEvents.emit("error", error) }
        }
    }
    static func main() {
        guard PluginRuntime.id == "launcher" else { return }
        if !CommandLine.arguments.contains("--protocol-test") {
            PluginDefaults.standard.migrate(prefixes: ["launcher."])
            if PluginDefaults.standard.object(forKey: "shortcut.open") == nil,
               let data = PluginDefaults.standard.data(forKey: "launcher.shortcut") {
                PluginDefaults.standard.set(String(data: data, encoding: .utf8) ?? "{}", forKey: "shortcut.open")
            }
            if !PluginDefaults.standard.bool(forKey: "sources.imported"), let old = PluginDefaults.standard.stringArray(forKey: "launcher.sources") {
                for (source, setting) in ["applications":"applications", "aiCommands":"aiCommands", "plugins":"plugins", "actions":"actions", "system":"systemCommands", "askAI":"quickAI"] { PluginDefaults.standard.set(old.contains(source), forKey: setting) }
                PluginDefaults.standard.set(true, forKey: "sources.imported")
            }
            do { try PluginRuntime.copyLegacy(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/com.yusuf.nook/Launcher"), to: PluginRuntime.data.appendingPathComponent("Launcher")) }
            catch { PluginEvents.emit("error", error.localizedDescription) }
        }
        if let data = PluginDefaults.standard.data(forKey: "launcher.history") { history = (try? JSONDecoder().decode([String: LauncherUsage].self, from: data)) ?? [:] }
        PluginRuntime.onReady = {
            LauncherApplicationIndex.shared.start(); registerShortcut()
            subscription = LauncherApplicationIndex.shared.$applications.receive(on: RunLoop.main).sink { _ in PluginEvents.emit("searchChanged", NSNull()) }
            PluginEvents.emit("ready", NSNull())
        }
        PluginRuntime.onStop = { LauncherApplicationIndex.disable(); LauncherAnswers.disable() }
        PluginRuntime.onEvent = { event, info in
            if event == "hotkey", info["id"] as? String == "open" { PluginRuntime.host("launcher.open") }
            if event == "settings" { registerShortcut() }
        }
        PluginRuntime.custom = { method, params, reply in
            switch method {
            case "launcher.search": search(params, reply: reply)
            case "launcher.activate": activate(params, reply: reply)
            case "launcher.clearHistory": history = [:]; save(); reply(NSNull(), nil)
            case "launcher.status": reply(["applications": LauncherApplicationIndex.shared.applications.count, "recent": history.count], nil)
            default: return false
            }
            return true
        }
        PluginRuntime.run()
    }
    static func search(_ params: [String: Any], reply: @escaping BridgeRegistry.Reply) {
        let raw = String((params["query"] as? String ?? "").prefix(512)), query = LauncherQuery(raw)
        let defaults = PluginDefaults.standard
        let sources = Set(LauncherSource.allCases.filter { source in
            let setting = source == .system ? "systemCommands" : source == .askAI ? "quickAI" : source.rawValue
            return defaults.object(forKey: setting) as? Bool != false
        })
        var rows: [[String: Any]] = []
        if sources.contains(.applications), defaults.object(forKey: "applications") as? Bool != false {
            rows += LauncherApplicationIndex.shared.applications.map { ["id": $0.id, "title": $0.name, "subtitle": "", "kind": "Application", "symbol": "app", "source": "applications"] }
        }
        rows += (params["items"] as? [[String: Any]] ?? []).prefix(2000).filter { sources.contains(LauncherSource(rawValue: $0["source"] as? String ?? "plugins") ?? .plugins) }
        if sources.contains(.system), defaults.object(forKey: "systemCommands") as? Bool != false {
            rows += [["id": "system:quit", "title": "Quit Nook", "symbol": "power", "confirm": true], ["id": "system:sleep", "title": "Sleep", "symbol": "moon.zzz", "confirm": true],
                     ["id": "system:darkMode", "title": "Toggle Dark Mode", "symbol": "circle.lefthalf.filled"],
                     ["id": "system:lock", "title": "Lock Screen", "symbol": "lock"],
                     ["id": "system:emptyTrash", "title": "Empty Trash", "symbol": "trash", "confirm": true]].map { $0.merging(["source": "system", "kind": "Command", "subtitle": "macOS"]) { old, _ in old } }
        }
        let documents = rows.compactMap { row -> LauncherSearchDocument? in
            guard let id = row["id"] as? String, let title = row["title"] as? String else { return nil }
            return LauncherSearchDocument(id: id, source: LauncherSource(rawValue: row["source"] as? String ?? "plugins") ?? .plugins, title: title, detail: row["subtitle"] as? String ?? "")
        }
        let ranked = LauncherRanking.ranked(documents, query: query, history: history, now: Date().timeIntervalSince1970)
        let byID = Dictionary(rows.compactMap { row in (row["id"] as? String).map { ($0, row) } }, uniquingKeysWith: { first, _ in first })
        let ids = query.characters.isEmpty && query.source == nil ? ranked.filter { history[$0] != nil || !$0.hasPrefix("app:") && !$0.hasPrefix("system:") } : ranked
        var items = ids.prefix(60).compactMap { byID[$0] }
        if sources.contains(.askAI), !query.text.isEmpty { items.append(["id": "askAI:" + query.text, "title": "Ask AI: " + query.text, "subtitle": "Uses your configured AI provider", "symbol": "sparkles", "kind": "AI", "keyEquivalent": "tab"]) }
        guard defaults.object(forKey: "smartAnswers") as? Bool != false, query.source == nil, !raw.isEmpty else { reply(["items": items], nil); return }
        LauncherAnswers.shared.request(raw, invalidated: { PluginEvents.emit("searchChanged", NSNull()) }) { answer in
            var result: [String: Any] = ["items": items]
            if let answer { result["answer"] = answer.json }
            reply(result, nil)
        }
    }
    static func activate(_ params: [String: Any], reply: @escaping BridgeRegistry.Reply) {
        let id = params["id"] as? String ?? ""
        let alternate = params["alternate"] as? Bool == true
        if id.hasPrefix("askAI:") {
            PluginRuntime.host("ai.complete", ["prompt": String(id.dropFirst(6))]) { value, error in
                guard error == nil, let text = value as? String else { reply(nil, error ?? "No AI answer."); return }
                reply(["answer": LauncherAnswer(section: "AI", expression: String(id.dropFirst(6)), leftBadge: "", result: text, rightBadge: "", copyValue: text).json], nil)
            }
        } else if id.hasPrefix("app:"), let app = LauncherApplicationIndex.shared.applications.first(where: { $0.id == id }) {
            let url = URL(fileURLWithPath: app.path)
            if alternate { NSWorkspace.shared.activateFileViewerSelecting([url]); reply(NSNull(), nil) }
            else { NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, error in
                DispatchQueue.main.async {
                    if error == nil { LauncherUsage.record(id, in: &history, at: Date().timeIntervalSince1970); save() }
                    reply(NSNull(), error?.localizedDescription)
                }
            } }
        } else if id.hasPrefix("system:") {
            let command = String(id.dropFirst(7))
            if ["sleep", "emptyTrash", "quit"].contains(command), params["confirmed"] as? Bool != true { reply(nil, "Confirm this action first."); return }
            let scripts = ["quit": "/usr/bin/osascript -e 'tell application id \"com.yusuf.nook\" to quit'", "sleep": "/usr/bin/pmset sleepnow", "darkMode": "/usr/bin/osascript -e 'tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode'", "emptyTrash": "/usr/bin/osascript -e 'tell application \"Finder\" to empty trash'"]
            if command == "lock" {
                PluginRuntime.host("notch.close")
                guard AXIsProcessTrusted() else { reply(nil, "Allow Accessibility to lock the screen."); return }
                let source = CGEventSource(stateID: .combinedSessionState)
                for down in [true, false] { let event = CGEvent(keyboardEventSource: source, virtualKey: 12, keyDown: down); event?.flags = [.maskControl, .maskCommand]; event?.post(tap: .cghidEventTap) }
                reply(NSNull(), nil)
            } else if let script = scripts[command] {
                PluginRuntime.host("shell", ["command": script]) { value, error in
                    let row = value as? [String: Any] ?? [:]
                    reply(NSNull(), error ?? ((row["code"] as? Int ?? 1) == 0 ? nil : row["stderr"] as? String ?? "Command failed."))
                }
            } else { reply(nil, "Unknown command.") }
        } else {
            LauncherUsage.record(id, in: &history, at: Date().timeIntervalSince1970); save()
            reply(["hostItemID": id], nil)
        }
    }
}

extension LauncherAnswer {
    var json: [String: Any] {
        var row: [String: Any] = ["section": section, "expression": expression, "leftBadge": leftBadge, "result": result, "rightBadge": rightBadge, "copyValue": copyValue, "isAvailable": isAvailable]
        row["note"] = note; row["copyWithUnits"] = copyWithUnits
        if let swatch { row["swatch"] = ["red": swatch.red, "green": swatch.green, "blue": swatch.blue] }
        row["secondaryActions"] = secondaryActions.map { action -> [String: Any] in
            switch action.value { case .copy(let value): return ["title": action.title, "copy": value]; case .open(let url): return ["title": action.title, "url": url.absoluteString] }
        }
        return row
    }
}
