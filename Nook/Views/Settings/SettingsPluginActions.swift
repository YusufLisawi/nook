import AppKit

/// Folder copies and Trash operations can take seconds for a large plugin. Publish and reveal only on the main actor.
@MainActor enum SettingsPluginActions {
    static func customize(_ tab: TabItem) async -> String? {
        guard let directory = tab.dir else { return nil }
        let plugins = Services.shared.plugins
        let bundled = plugins.isBundled(tab)
        let target = bundled ? PluginRegistry.userDir.appendingPathComponent(tab.id, isDirectory: true) : directory
        if bundled {
            do {
                try await Task.detached(priority: .userInitiated) {
                    if !FileManager.default.fileExists(atPath: target.path) {
                        try FileManager.default.copyItem(at: directory, to: target)
                    }
                }.value
            } catch { return "Couldn’t create your editable copy: \(error.localizedDescription)" }
            await plugins.reloadForSettings()
        }
        NSWorkspace.shared.activateFileViewerSelecting([target.appendingPathComponent("plugin.json")])
        return nil
    }

    static func revert(_ tab: TabItem) async -> String? {
        let plugins = Services.shared.plugins
        guard plugins.overridesBundled(tab), let directory = tab.dir else { return nil }
        do {
            try await Task.detached(priority: .userInitiated) {
                try FileManager.default.trashItem(at: directory, resultingItemURL: nil)
            }.value
        } catch { return "Couldn’t move your custom copy to the Trash: \(error.localizedDescription)" }
        await plugins.reloadForSettings()
        return nil
    }
}
