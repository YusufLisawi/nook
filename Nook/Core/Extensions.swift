import SwiftUI

/// Extension points so features live in their own files instead of editing shared switches.
///
///   BridgeRegistry.register("files", functions: ["search", "open"]) { fn, args, pluginID, reply in … }
///   → plugins get `nook.files.search(...)`, `nook.files.open(...)`
///
///   SettingsRegistry.register(id: "windows", title: "Window Management", symbol: "macwindow", tint: .teal, order: 35) { WindowsPane() }
///   → a pane in the Settings sidebar
enum BridgeRegistry {
    typealias Handler = (_ fn: String, _ args: [Any], _ pluginID: String, _ reply: @escaping (Any?, String?) -> Void) -> Void

    private(set) static var namespaces: [String: (functions: [String], handler: Handler)] = [:]

    static func register(_ namespace: String, functions: [String], handler: @escaping Handler) {
        namespaces[namespace] = (functions, handler)
    }

    /// `ns.fn` → true if a registered namespace handled it.
    static func handle(_ full: String, args: [Any], pluginID: String, reply: @escaping (Any?, String?) -> Void) -> Bool {
        guard let dot = full.firstIndex(of: "."), let entry = namespaces[String(full[..<dot])] else { return false }
        entry.handler(String(full[full.index(after: dot)...]), args, pluginID, reply)
        return true
    }

    /// JS that adds `nook.<ns>.<fn>(...)` for every registered namespace (appended to the bridge script).
    static var javascript: String {
        let spec = namespaces.mapValues(\.functions)
        let json = (try? JSONSerialization.data(withJSONObject: spec)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return """
        (() => { const spec = \(json);
          for (const [ns, fns] of Object.entries(spec)) {
            window.nook[ns] = Object.fromEntries(fns.map(f => [f, (...a) => window.webkit.messageHandlers.nook.postMessage({ fn: ns + '.' + f, args: a })]));
          } })();
        """
    }
}

struct SettingsExtension: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let tint: Color
    let order: Int
    let view: () -> AnyView
}

enum SettingsRegistry {
    private(set) static var panes: [SettingsExtension] = []

    static func register<V: View>(id: String, title: String, symbol: String, tint: Color, order: Int, @ViewBuilder view: @escaping () -> V) {
        panes.removeAll { $0.id == id }
        panes.append(SettingsExtension(id: id, title: title, symbol: symbol, tint: tint, order: order, view: { AnyView(view()) }))
        panes.sort { $0.order < $1.order }
    }
}
