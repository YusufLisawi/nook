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
    guard PluginRuntime.id == "commands" else { return }
    do { try migrate(["ai-commands.json"], prefixes: ["aiCommands"]) } catch {
      fputs("Migration failed: \(error)\n", stderr)
      return
    }
    let service = AICommands()
    PluginRuntime.onReady = {
      service.closeNotches = { PluginRuntime.host("notch.close") }
      service.openTab = { _ in PluginRuntime.host("notch.open") }
      service.registerShortcuts()
      PluginEvents.emit("ready", NSNull())
      PluginRuntime.host("runtime.keepAlive", ["enabled": false])
    }
    PluginRuntime.onEvent = { event, info in
      if event == "actionAlternate" { PluginRuntime.host("settings.open") }
      if event == "hotkey", let key = info["id"] as? String {
        service.run(key, fromNotch: false, context: info["context"] as? String)
      }
      if event == "action", let key = info["value"] as? String {
        service.run(key, fromNotch: true, context: PluginRuntime.context)
      }
    }
    PluginRuntime.custom = { method, p, reply in
      if method == "ai.complete" {
        PluginRuntime.beginWork()
        Task { @MainActor in
          defer { PluginRuntime.endWork() }
          do {
            reply(
              try await AIBrain.complete(
                provider: p["provider"] as? String ?? "codex",
                model: p["model"] as? String ?? "gpt-6-luna",
                effort: p["effort"] as? String ?? "none", prompt: p["prompt"] as? String ?? "",
                onDelta: { text in
                  PluginEvents.emit("aiDelta", ["requestID": p["requestID"] ?? "", "text": text])
                }), nil)
          } catch { reply(nil, error.localizedDescription) }
        }
        return true
      }
      guard method.hasPrefix("commands.") else { return false }
      PluginRuntime.context = p["__context"] as? String ?? PluginRuntime.context
      service.handle(String(method.dropFirst(9)), args: p["args"] as? [Any] ?? [], reply: reply)
      return true
    }
    PluginRuntime.onStop = { service.stop() }
    PluginRuntime.run()
  }
}
