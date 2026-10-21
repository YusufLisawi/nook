import SwiftUI

/// Store UI state is independent of notch/plugin lifetimes.
@MainActor final class PluginStore: ObservableObject {
    static let shared = PluginStore()
    let client = PluginStoreClient()
    @Published private(set) var entries: [PluginStoreEntry] = []
    @Published private(set) var installations: [String: PluginStoreInstallation] = [:]
    @Published private(set) var loading = false
    @Published private(set) var busyID: String?
    @Published private(set) var message: String?
    @Published private(set) var error: String?
    @Published var selectedID: String?

    static func register() {
        SettingsRegistry.register(id: "plugin-store", title: "Plugin Store", symbol: "shippingbox.fill", tint: .orange, order: 50) {
            PluginStorePane()
        }
    }

    func open(_ id: String?) {
        guard let id, PluginStorePackage.validID(id) else { return }
        selectedID = id
        (NSApp.delegate as? AppDelegate)?.showSettings(pane: "plugin-store")
    }

    func refresh() async {
        guard !loading else { return }
        loading = true
        error = nil
        defer { loading = false }
        if entries.isEmpty, let cached = await client.cachedCatalog() {
            entries = cached.plugins
            message = cached.message
        }
        await refreshInstallations()
        do {
            let catalog = try await client.catalog(force: true)
            entries = catalog.plugins
            message = catalog.message
        } catch { self.error = error.localizedDescription }
    }

    func refreshInstallations() async { installations = await client.installations() }

    func install(_ entry: PluginStoreEntry, update: Bool) async {
        guard busyID == nil else { return }
        busyID = entry.id
        error = nil
        defer { busyID = nil }
        do {
            try await client.install(entry, update: update, approve: PluginAutomaticUpdates.approve)
            changed()
        } catch { self.error = error.localizedDescription }
        await refreshInstallations()
    }

    func uninstall(_ entry: PluginStoreEntry) async {
        guard busyID == nil else { return }
        busyID = entry.id
        error = nil
        defer { busyID = nil }
        do {
            try await client.uninstall(entry.id)
            changed()
        } catch { self.error = error.localizedDescription }
        await refreshInstallations()
    }

    private func changed() {
        Services.shared.plugins.reload()
        Services.shared.plugins.touch()
    }
}
