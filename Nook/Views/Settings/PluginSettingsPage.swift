import SwiftUI
import WebKit

/// A contributed page gets the same gated bridge and UI kit as the plugin's notch page.
struct PluginSettingsPage: NSViewRepresentable {
  let tab: TabItem
  let entry: String
  final class Coordinator {
    let host = WebPluginHost()
    deinit { PluginEngine.shared.removeOwner(host.keyboardID) }
  }
  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> WKWebView {
    context.coordinator.host.entryOverride = entry
    let view = context.coordinator.host.view(for: tab) ?? WKWebView()
    PluginEngine.shared.setVisible(owner: context.coordinator.host.keyboardID, plugin: tab.id)
    return view
  }
  func updateNSView(_ view: WKWebView, context: Context) {}
  static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
    view.stopLoading()
    PluginEngine.shared.removeOwner(coordinator.host.keyboardID)
  }
}

struct PluginSettingsDestination: View {
  let pluginID: String
  @ObservedObject private var plugins = Services.shared.plugins
  var body: some View {
    if let tab = plugins.tabs.first(where: { $0.id == pluginID }), let dir = tab.dir,
      let manifest = try? PluginManifestV2(directory: dir),
      let entry = manifest.contributes["settings"]?.first?["entry"] as? String
    {
      PluginSettingsPage(tab: tab, entry: entry)
    } else {
      ContentUnavailableView(
        "Plugin unavailable", systemImage: "puzzlepiece.extension",
        description: Text("Install and enable this plugin in Plugin Store."))
    }
  }
}
