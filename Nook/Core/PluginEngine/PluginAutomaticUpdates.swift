import AppKit

private struct PluginConsentDeclined: LocalizedError {
    var errorDescription: String? { "Plugin access was not approved. The previous version is unchanged." }
}

/// No catalog reachability requirement at startup: existing/bundled plugins keep working offline.
@MainActor final class PluginAutomaticUpdates {
    static let shared = PluginAutomaticUpdates()
    private let client = PluginStoreClient()
    private var timer: Timer?
    private var checking = false
    private var lastAttempt = Date.distantPast

    static func start() {
        Task { @MainActor in
            await shared.check()
            shared.timer = Timer.scheduledTimer(withTimeInterval: 86_400, repeats: true) { _ in Task { @MainActor in await shared.check() } }
        }
    }
    static func approve(_ json: [String: Any], _ directory: URL) async throws {
        let manifest = try PluginManifestV2(json: json, directory: directory)
        guard manifest.apiVersion == 2 else { return }
        guard await PluginPermissions.shared.review(manifest) else { throw PluginConsentDeclined() }
    }
    func check(settingsOpened: Bool = false) async {
        guard !checking, Date().timeIntervalSince(lastAttempt) > (settingsOpened ? 30 : 86_000) else { return }
        checking = true; lastAttempt = Date()
        defer { checking = false }
        do {
            let catalog = try await client.catalog(force: true)
            guard !catalog.cached, catalog.message == nil else { return }
            let installed = await client.installations()
            let bootstrapped = UserDefaults.standard.bool(forKey: "pluginV2DefaultsInstalled")
            var declinedDefaults = Set(UserDefaults.standard.stringArray(forKey: "pluginV2DeclinedDefaults") ?? [])
            var defaultsSucceeded = true
            for entry in catalog.plugins {
                let current = installed[entry.id]
                let preinstall = !bootstrapped && entry.default == true && current == nil && !declinedDefaults.contains(entry.id)
                let update = current?.receipt != nil && current?.receipt?.sha != entry.sha
                guard preinstall || update else { continue }
                do {
                    try await client.install(entry, update: update, approve: Self.approve)
                    Services.shared.plugins.reload(); Services.shared.plugins.touch()
                } catch {
                    if preinstall {
                        if error is PluginConsentDeclined {
                            declinedDefaults.insert(entry.id)
                            UserDefaults.standard.set(declinedDefaults.sorted(), forKey: "pluginV2DeclinedDefaults")
                        } else { defaultsSucceeded = false }
                    }
                    PluginLog.write(entry.id, level: "store", message: error.localizedDescription)
                }
            }
            if !bootstrapped, defaultsSucceeded { UserDefaults.standard.set(true, forKey: "pluginV2DefaultsInstalled") }
        } catch { PluginLog.write("store", level: "info", message: "Offline: \(error.localizedDescription)") }
    }
}
