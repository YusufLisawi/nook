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
        AgentService.register()
        WindowManager.shared.start()
        ClipsFeature.start()
        PluginStore.register()
        FileSearchService.shared.register()
        plugins.start()
        media.start()
        proxy.restoreOnLaunch()
        dictation.start()
        audio.start()
        links.start()
    }

    func shutdown() {
        AgentService.shared.shutdown()
        proxy.shutdown()
        audio.shutdown() // remove taps so no app is left muted
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
    private static var url: URL { Services.supportDir.appendingPathComponent(".secrets") }

    static func get(_ key: String) -> String? { load()[key].flatMap { $0.isEmpty ? nil : $0 } }

    static func set(_ key: String, _ value: String?) {
        var dict = load()
        dict[key] = value
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: String] ?? [:]
    }
}
