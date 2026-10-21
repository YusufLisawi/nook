import AppKit
@main enum ClipsHelper {
    static func reconcileScreenshots() {
                if Features.shared.enabled("screenshots") {
                    ScreenCaptureIndex.shared.start(directory: PluginRuntime.data.appendingPathComponent("Clips"), accessAllowed: { url in
                        CaptureFolderScope.allows(url, scopes: PluginRuntime.scopes)
                    })
                } else { ScreenCaptureIndex.disable() }
    }
    static func main() {
        guard PluginRuntime.id == "clips" else { return }
        if !CommandLine.arguments.contains("--protocol-test") {
            do { try ClipMigration.run() } catch { PluginEvents.emit("error", "History migration failed: " + error.localizedDescription); return }
        }
        ClipsFeature.start()
        PluginRuntime.onReady = {
            PluginRuntime.host("files.scopes") { value, error in
                guard error == nil else { return }
                PluginRuntime.scopes = value as? [String] ?? []
                PluginEvents.emit("ready", NSNull())
                ClipPreferences.register()
                ClipboardHistory.shared.start()
                reconcileScreenshots()
            }
        }
        PluginRuntime.onEvent = { event, _ in
            if event == "settings" { reconcileScreenshots() }
        }
        PluginRuntime.onStop = { ClipboardHistory.disable(); ScreenCaptureIndex.disable(); ClipsActions.shared.stop() }
        PluginRuntime.run()
    }
}
