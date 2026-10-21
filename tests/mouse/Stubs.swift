import Foundation

// No service startup, user preferences, permissions or event posting is performed by these tests.
enum PluginEvents {
    static func emit(_ event: String, _ payload: Any, to pluginID: String? = nil) {}
}
final class Services {
    static let shared = Services()
    let dictation = Dictation()
    final class Dictation {
        let hotkeys = HotkeyMonitor()
        func reloadShortcuts() {}
    }
}
