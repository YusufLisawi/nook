import AppKit
import SwiftUI

struct HelperFailure: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}
struct PluginActivity {
  var pluginID: String
  var text: String
  var symbol: String
  var color: String
}
final class HelperHotkeys {
  var hold: DictationShortcut?
  var toggle: DictationShortcut?
  var isTrusted: Bool { true }
  var paused = false
  var onHoldStart: () -> Void = {}
  var onHoldEnd: () -> Void = {}
  var onHoldCancel: () -> Void = {}
  var onToggle: () -> Void = {}
}
struct DictationShortcut: Codable, Equatable {
  var keyCode: Int?
  var modifiers: UInt64
  var display: String
  static let defaultHold = DictationShortcut(keyCode: nil, modifiers: 786432, display: "⌃⌥")
  static let defaultToggle = DictationShortcut(keyCode: 49, modifiers: 524288, display: "⌥Space")
  static func load(_ key: String, fallback: DictationShortcut) -> DictationShortcut? {
    guard let data = PluginDefaults.standard.data(forKey: key) else { return fallback }
    return data.isEmpty ? nil : try? JSONDecoder().decode(Self.self, from: data)
  }
}
enum Notifier {
  static func post(title: String, body: String) {
    PluginRuntime.host("notifications.post", ["title": title, "body": body])
  }
}
enum SettingsPersistence {
  static let shared = Writer()
  struct Writer { func submit(id: String, _ write: () -> Void) { write() } }
}
enum Secrets {
  static func get(_ key: String) -> String? {
    (try? PluginRuntime.sync("secrets.get", ["key": key])) as? String
  }
  static func set(_ key: String, _ value: String?) {
    PluginRuntime.host(
      value == nil ? "secrets.remove" : "secrets.set", ["key": key, "value": value ?? ""])
  }
}
enum FeatureVisibility { static func isVisible(_ id: String) -> Bool { true } }
