import Foundation

final class MicRecorder {
  struct Mic {
    let id: String
    let name: String
  }
  private(set) var level: Float = 0
  private(set) var peak: Int16 = 0
  static func microphones() -> [Mic] {
    let rows = (try? PluginRuntime.sync("microphone.devices")) as? [[String: String]] ?? []
    return rows.map { Mic(id: $0["id"] ?? "", name: $0["name"] ?? "") }
  }
  func start(deviceUID: String?, to url: URL) throws {
    _ = try PluginRuntime.sync(
      "microphone.start", ["deviceUID": deviceUID ?? "", "path": url.path])
    peak = 0
  }
  func stop() -> Double {
    let result = (try? PluginRuntime.sync("microphone.stop")) as? [String: Any] ?? [:]
    peak = Int16(clamping: result["peak"] as? Int ?? 0)
    level = 0
    return result["duration"] as? Double ?? 0
  }
}
