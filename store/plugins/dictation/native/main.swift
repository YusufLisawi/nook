import AppKit

@main enum DailyHelper {
  static func migrate(_ names: [String], prefixes: [String]) throws {
    PluginDefaults.standard.migrate(prefixes: prefixes)
    let legacy = URL(
      fileURLWithPath: ProcessInfo.processInfo.environment["NOOK_LEGACY_DIR"] ?? NSHomeDirectory()
        + "/Library/Application Support/Nook")
    for name in names {
      try PluginRuntime.copyLegacy(
        legacy.appendingPathComponent(name), to: PluginRuntime.data.appendingPathComponent(name))
    }
  }
  static func shortcuts() {
    var rows: [[String: Any]] = []
    for (id, key, fallback) in [
      ("hold", "dictationHoldShortcut", DictationShortcut.defaultHold),
      ("toggle", "dictationToggleShortcut", .defaultToggle),
    ] {
      if let k = DictationShortcut.load(key, fallback: fallback) {
        var row: [String: Any] = [
          "id": id, "mode": id, "modifiers": k.modifiers, "display": k.display,
          "title": id == "hold" ? "Hold to Talk" : "Toggle Recording",
        ]
        if let c = k.keyCode { row["keyCode"] = c }
        rows.append(row)
      }
    }
    PluginRuntime.host("hotkeys.replace", ["items": rows])
  }
  static func main() {
    guard PluginRuntime.id == "dictation" else { return }
    do { try migrate(["Dictation"], prefixes: ["dictation"]) } catch {
      fputs("Migration failed: \(error)\n", stderr)
      return
    }
    let service = DictationService()
    PluginRuntime.onReady = {
      service.start()
      shortcuts()
      PluginEvents.emit("ready", NSNull())
      PluginRuntime.host("runtime.keepAlive", ["enabled": false])
    }
    PluginRuntime.onEvent = { event, info in
      if event == "settings" {
        service.reloadShortcuts()
        service.cleanupRecordings()
        shortcuts()
      }
      if event == "hotkey", let key = info["id"] as? String {
        let phase = info["phase"] as? String ?? "pressed"
        if key == "hold" {
          if phase == "pressed" {
            service.begin(context: info["context"] as? String)
          } else {
            service.finish(cancel: phase == "cancelled")
          }
        }
        if key == "toggle", phase == "pressed" { service.toggle(context: info["context"] as? String) }
      }
    }
    PluginRuntime.custom = { method, p, reply in
      if method == "dictation.shortcut", let mode = p["mode"] as? String,
        ["hold", "toggle"].contains(mode)
      {
        let data =
          (p["value"] as? [String: Any]).flatMap { try? JSONSerialization.data(withJSONObject: $0) }
          ?? Data()
        PluginDefaults.standard.set(
          data, forKey: mode == "hold" ? "dictationHoldShortcut" : "dictationToggleShortcut")
        service.reloadShortcuts()
        shortcuts()
        reply(NSNull(), nil)
        return true
      }
      guard method.hasPrefix("dictation.") else { return false }
      service.handle(String(method.dropFirst(10)), args: p["args"] as? [Any] ?? [], context: p["__context"] as? String, reply: reply)
      return true
    }
    PluginRuntime.onStop = { service.stop() }
    PluginRuntime.run()
  }
}
