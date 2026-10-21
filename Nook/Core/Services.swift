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
    var links: LinkCatcher { service("links", LinkCatcher.init) }
    let plugins = PluginRegistry()

    /// Set by web plugins through `nook.activity.set`; shown on the closed notch.
    @Published var pluginActivity: PluginActivity?

    @MainActor func start() {
        PluginDailyMigration.captureLegacyInstall()
        Features.shared.start(self)
        plugins.start()
        PluginEngine.start()
    }

    func shutdown() {
        PluginEngine.shared.shutdown()
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
    var level: Float? = nil
    var startedAt: Date? = nil
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

/// Host-owned account vault. Existing plaintext data is read-only migration input.
enum Secrets {
    private static let legacy = SettingsJSONFile<[String: String]>(
        url: { Services.supportDir.appendingPathComponent(".secrets") }, fallback: [:], permissions: 0o600)
    static func get(_ key: String) -> String? {
        if let value = try? PluginKeychain.call(id:"accounts",method:"secrets.get",key:key,value:"") as? String, !value.isEmpty { return value }
        guard !UserDefaults.standard.bool(forKey:"accountSecretMigrated." + key), let value = legacy.read()[key], !value.isEmpty else { return nil }
        set(key,value); return value
    }
    static func set(_ key: String, _ value: String?) {
        do {
            _ = try PluginKeychain.call(id:"accounts",method:value == nil || value?.isEmpty == true ? "secrets.remove" : "secrets.set",key:key,value:value ?? "")
            UserDefaults.standard.set(true,forKey:"accountSecretMigrated." + key)
        } catch { PluginLog.write("accounts",level:"error",message:error.localizedDescription) }
    }
}
