import Foundation

/// App-wide services shared by every notch (one notch per screen).
final class Services: ObservableObject {
    static let shared = Services()

    static let supportDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Nook", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    let media = MediaController()
    let timers = TimerService()
    let shelf = FileShelf()
    let system = SystemStats()
    let proxy = ProxyService()
    let dictation = DictationService()
    let audio = AudioMixer()
    let links = LinkCatcher()
    let commands = AICommands()
    let plugins = PluginRegistry()

    /// Set by web plugins through `nook.activity.set`; shown on the closed notch.
    @Published var pluginActivity: PluginActivity?

    @MainActor func start() {
        CleanerBridge.register()
        AgentService.register()
        WindowManager.shared.start()
        ClipsFeature.start()
        PluginStore.register()
        FileSearchService.shared.register()
        KeyboardActions.shared.start()
        NativeShortcutIntegration.register()
        LauncherFeature.start()
        plugins.start()
        media.start()
        proxy.restoreOnLaunch()
        dictation.start()
        audio.start()
        PluginEngine.start()
        links.start()
    }

    func shutdown() {
        FileNameIndex.shared.shutdown()
        AgentService.shared.shutdown()
        SettingsPersistence.shared.flush()
        proxy.shutdown()
        audio.shutdown() // remove taps so no app is left muted
        PluginEngine.shared.shutdown()
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
