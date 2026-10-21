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
  static func main() {
    guard PluginRuntime.id == "mixer" else { return }
    do { try migrate([], prefixes: ["audio"]) } catch {
      fputs("Migration failed: \(error)\n", stderr)
      return
    }
    let service = AudioMixer()
    PluginRuntime.onReady = {
      service.start()
      PluginEvents.emit("ready", NSNull())
      PluginRuntime.host("runtime.keepAlive", ["enabled": false])
    }
    PluginRuntime.onEvent = { event, info in }
    PluginRuntime.custom = { method, p, reply in
      guard method.hasPrefix("audio.") else { return false }
      service.handle(String(method.dropFirst(6)), args: p["args"] as? [Any] ?? [], reply: reply)
      return true
    }
    PluginRuntime.onStop = { service.shutdown() }
    PluginRuntime.run()
  }
}
