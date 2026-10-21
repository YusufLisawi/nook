import AppKit
@main enum WindowsHelper {
    static func shortcuts() {
        var values: [String: TabHotkey] = [:]
        for action in WindowAction.allCases {
            if let raw = PluginDefaults.standard.string(forKey: "shortcut." + action.rawValue),
               let key = try? JSONDecoder().decode(TabHotkey.self, from: Data(raw.utf8)) { values[action.rawValue] = key }
        }
        WindowShortcuts.shared.failures = [:]
        let old = WindowShortcuts.shared.all()
        for key in old.keys { PluginRuntime.host("hotkeys.unregister", ["id": key]) }
        PluginDefaults.standard.set(try? JSONEncoder().encode(values), forKey: WindowShortcuts.storageKey)
        for (key, value) in values where WindowAction(rawValue: key) != nil {
            PluginRuntime.host("hotkeys.register", ["id": key, "keyCode": value.keyCode, "modifiers": value.modifiers, "display": value.display, "title": WindowAction(rawValue: key)!.title]) { _, error in
                if let error { WindowShortcuts.shared.failures[key] = error; PluginEvents.emit("windowsError", error); PluginEvents.emit("windows", NSNull()) }
            }
        }
    }
    static func main() {
        guard PluginRuntime.id == "windows" else { return }
        if !CommandLine.arguments.contains("--protocol-test") {
            PluginDefaults.standard.migrate(prefixes: ["windowManagement"])
            for (action, key) in WindowShortcuts.shared.all() where PluginDefaults.standard.object(forKey: "shortcut." + action) == nil {
                if let data = try? JSONEncoder().encode(key), let value = String(data: data, encoding: .utf8) { PluginDefaults.standard.set(value, forKey: "shortcut." + action) }
            }
        }
        WindowManager.shared.start()
        PluginRuntime.onReady = { shortcuts(); PluginEvents.emit("ready", NSNull()) }
        PluginRuntime.onEvent = { event, info in
            if event == "beforeOpen" { WindowManager.shared.capture(info) }
            if event == "settings" { shortcuts() }
            if event == "hotkey", let id = info["id"] as? String, let action = WindowAction(rawValue: id), let key = WindowShortcuts.shared.get(action) { _ = WindowManager.shared.handleShortcut(key: Int64(key.keyCode), modifiers: CGEventFlags(rawValue: key.modifiers), from: info["context"] as? String) }
        }
        PluginRuntime.custom = { method, p, reply in
            guard method == "windows.state" || method == "windows.apply" else { return false }
            var args = p["args"] as? [Any] ?? []
            if method == "windows.state" { args = [p["__context"] as? String ?? PluginRuntime.context] }
            else { args = [args.first ?? "", p["__context"] as? String ?? PluginRuntime.context] }
            BridgeRegistry.handlers["windows"]?(method == "windows.state" ? "state" : "apply", args, "windows", reply)
            return true
        }
        PluginRuntime.onStop = { WindowManager.disable() }
        PluginRuntime.run()
    }
}
