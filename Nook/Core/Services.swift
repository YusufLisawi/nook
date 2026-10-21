import Foundation

/// App-wide services shared by every notch (one notch per screen).
final class Services: ObservableObject {
    static let shared = Services()

    static let supportDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Nook", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private var instances: [String: AnyObject] = [:]
    let hotkeys = HotkeyMonitor()
    var closeNotches: () -> Void = {}
    var openTab: (String) -> Void = { _ in }
    private func service<T: AnyObject>(_ id: String, _ make: () -> T) -> T {
        if let value = instances[id] as? T { return value }
        let value = make(); instances[id] = value; return value
    }
    func release(_ id: String, stop: (AnyObject) -> Void = { _ in }) {
        guard let value = instances.removeValue(forKey: id) else { return }; stop(value)
    }
    var media: MediaController { service("media", MediaController.init) }
    var timers: TimerService { service("timers", TimerService.init) }
    var shelf: FileShelf { service("shelf", FileShelf.init) }
    var system: SystemStats { service("system", SystemStats.init) }
    var proxy: ProxyService { service("proxy", ProxyService.init) }
    var dictation: DictationService { service("dictation", DictationService.init) }
    var audio: AudioMixer { service("audio", AudioMixer.init) }
    var mouse: MouseFixService { service("mouse", MouseFixService.init) }
    var links: LinkCatcher { service("links", LinkCatcher.init) }
    var commands: AICommands {
        service("commands") {
            let value = AICommands()
            value.closeNotches = { [weak self] in self?.closeNotches() }
            value.openTab = { [weak self] in self?.openTab($0) }
            return value
        }
    }
    let plugins = PluginRegistry()

    /// Set by web plugins through `nook.activity.set`; shown on the closed notch.
    @Published var pluginActivity: PluginActivity?

    @MainActor func start() {
        Features.shared.start(self)
        plugins.start()
    }

    func shutdown() {
        Features.shared.shutdown()
        SettingsPersistence.shared.flush()
        instances.removeAll()
    }

}

struct PluginActivity: Equatable {
    var pluginID: String
    var text: String
    var symbol: String
    var color: String
}

extension Notification.Name {
    /// userInfo: ["event": String, "payload": Any] — forwarded to every web plugin as `nook.on(event)`.
    static let nookPluginEvent = Notification.Name("nookPluginEvent")
}

enum PluginEvents {
    /// `to`: only this plugin id receives it (nil = every plugin).
    static func emit(_ event: String, _ payload: Any, to pluginID: String? = nil) {
        var info: [String: Any] = ["event": event, "payload": payload]
        if let pluginID { info["plugin"] = pluginID }
        NotificationCenter.default.post(name: .nookPluginEvent, object: nil, userInfo: info)
    }
}

/// Small JSON-file secret store (0600), like FreeFlow's `.settings`.
enum Secrets {
    private static let store = SettingsJSONFile<[String: String]>(
        url: { Services.supportDir.appendingPathComponent(".secrets") }, fallback: [:], permissions: 0o600)

    static func get(_ key: String) -> String? { store.read()[key].flatMap { $0.isEmpty ? nil : $0 } }

    static func set(_ key: String, _ value: String?) {
        guard store.read()[key] != value else { return }
        store.update { $0[key] = value }
    }
}
