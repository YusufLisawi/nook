import AppKit

/// Value-only native search surface. Discovery, ranking, history and answers live in providers.
enum PluginSearch {
    struct Provider { let pluginID: String; let method: String; let actionMethod: String }
    static let queue = PluginSearchQueue()
    static var providers: [String: Provider] = [:]
    static func install(_ manifest: PluginManifestV2) {
        for row in manifest.contributes["searchProviders"] ?? [] {
            guard let key = row["id"] as? String, let method = row["method"] as? String, let action = row["actionMethod"] as? String else { continue }
            providers[manifest.id + "/" + key] = Provider(pluginID: manifest.id, method: method, actionMethod: action)
        }
    }
    static func remove(_ id: String) { queue.cancel(prefix: id + "/"); providers = providers.filter { $0.value.pluginID != id } }
    static func open(_ vm: NotchViewModel?) {
        guard let vm else { return }
        (NSApp.delegate as? AppDelegate)?.openLauncher(in: vm)
    }
}
