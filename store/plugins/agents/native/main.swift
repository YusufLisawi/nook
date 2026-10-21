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
    guard PluginRuntime.id == "agents" else { return }
    do { try migrate(["agents.json", "AgentSessions"], prefixes: []) } catch {
      fputs("Migration failed: \(error)\n", stderr)
      return
    }
    let service = AgentService.shared
    PluginRuntime.onReady = {
      PluginEvents.emit("ready", NSNull())
      PluginRuntime.host("runtime.keepAlive", ["enabled": false])
    }
    PluginRuntime.onEvent = { event, info in }
    PluginRuntime.custom = { method, p, reply in
      guard method.hasPrefix("agents.") else { return false }
      do {
        reply(try service.handle(String(method.dropFirst(7)), args: p["args"] as? [Any] ?? []), nil)
      } catch { reply(nil, error.localizedDescription) }
      return true
    }
    PluginRuntime.onStop = { service.shutdown() }
    PluginRuntime.run()
  }
}
