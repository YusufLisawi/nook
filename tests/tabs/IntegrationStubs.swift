import AppKit
import Combine
import WebKit

/// All app preference calls are shadowed in memory; no process-wide Nook domain is read or written.
final class UserDefaults {
    static let standard = UserDefaults()
    static let didChangeNotification = Foundation.UserDefaults.didChangeNotification
    var values: [String: Any] = [:]
    init() {}
    convenience init?(suiteName: String) { self.init() }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func dictionary(forKey key: String) -> [String: Any]? { values[key] as? [String: Any] }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func register(defaults: [String: Any]) { for (key, value) in defaults where values[key] == nil { values[key] = value } }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }
}

struct StubScreen { let frame = CGRect(x: 0, y: 0, width: 1800, height: 1000) }
struct NotchGeometry {
    let screen = StubScreen()
    let notch = CGRect(x: 800, y: 970, width: 200, height: 30)
}
struct TabItem: Equatable, Identifiable {
    let id: String
    let name: String
    var isWeb: Bool { true }
    let symbol = "square"
    let height: CGFloat
}
final class PluginRegistry: ObservableObject {
    static let defaultHeight: CGFloat = 210
    static let maxHeight: CGFloat = 400
    @Published var tabs = [TabItem(id: "home", name: "Home", height: 210), .init(id: "notes", name: "Notes", height: 300), .init(id: "files", name: "Files", height: 120), .init(id: "clips", name: "Clips", height: 360)]
    @Published var customOrder: [String] = []
    @Published var userHeights: [String: CGFloat] = [:]
    var orderedTabs: [TabItem] { tabs }
    func height(for tab: TabItem) -> CGFloat { userHeights[tab.id] ?? tab.height }
}
final class StubHotkeys {
    var paused = false
    var hold: DictationShortcut? { DictationShortcut.load(DictationService.Keys.holdShortcut, fallback: .defaultHold) }
    var toggle: DictationShortcut? { DictationShortcut.load(DictationService.Keys.toggleShortcut, fallback: .defaultToggle) }
}
final class DictationService: ObservableObject {
    enum Phase: Equatable { case idle, recording, transcribing, done, failed }
    enum Keys { static let holdShortcut = "hold"; static let toggleShortcut = "toggle" }
    @Published var phase = Phase.idle
    let hotkeys = StubHotkeys()
    func reloadShortcuts() {}
}
final class MediaController: ObservableObject {
    struct Track { let isPlaying: Bool }
    @Published var track: Track?
}
final class TimerService: ObservableObject {
    @Published var isRunning = false
    var onFinish: (() -> Void)?
}
final class AICommands: ObservableObject {
    struct Command { let id: String; let name: String; var enabled = true; var hotkey: TabHotkey? }
    @Published var commands: [Command] = []
    func run(_ id: String, fromNotch: Bool) {}
    func setHotkey(_ id: String, _ hotkey: TabHotkey?) {
        if let index = commands.firstIndex(where: { $0.id == id }) { commands[index].hotkey = hotkey }
    }
}
struct PluginActivity: Equatable { var text: String }
final class Services: ObservableObject {
    static let shared = Services()
    let plugins = PluginRegistry()
    let dictation = DictationService()
    let commands = AICommands()
    let media = MediaController()
    let timers = TimerService()
    @Published var pluginActivity: PluginActivity?
}
final class WebPluginHost {
    let keyboardID = "display-a"
    var events: [(String, Any)] = []
    init(vm: NotchViewModel) {}
    func view(for tab: TabItem) -> WKWebView? { nil }
    func emit(_ event: String, _ payload: Any, to pluginID: String? = nil) { events.append((event, payload)) }
}
final class WindowManager {
    static let shared = WindowManager()
    var captures = 0
    func captureBeforeNotchOpen(_ vm: NotchViewModel) { captures += 1 }
    func handleShortcut(key: Int64, modifiers: CGEventFlags, from notch: NotchViewModel? = nil) -> Bool { false }
}
final class AppDelegate: NSObject, NSApplicationDelegate { func showSettings(pane: String?) {} }
final class NotchPanel: NSPanel {}
enum PluginEvents { static func emit(_ event: String, _ payload: Any, to pluginID: String? = nil) {} }
enum PluginContributions { static let actionOwner = "plugin-engine" }
final class PluginHostAPI {
    static let shared = PluginHostAPI()
    func captureBeforeOpen(_ vm: NotchViewModel) {}
}
extension Notification.Name { static let nookKeyboardFocus = Notification.Name("nookKeyboardFocus") }

// Native Files owns its local shortcuts only while its view is present.
enum FileSearchTabState { static func handle(_ event: NSEvent, owner: String) -> Bool { false } }
