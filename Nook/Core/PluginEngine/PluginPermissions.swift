import AppKit
import SwiftUI

/// Grants are distinct from manifest declarations. An absent/revoked grant always fails closed.
final class PluginPermissions: ObservableObject {
    static let shared = PluginPermissions()
    private let key = "pluginV2Grants"
    @Published private(set) var grants: [String: PluginPermissionGrant]
    private var reviewing = Set<String>()
    private var deniedThisSession = Set<String>()
    private var presenting = false
    private var reviewQueue: [CheckedContinuation<Void, Never>] = []

    private init() {
        grants = UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode([String: PluginPermissionGrant].self, from: $0) } ?? [:]
    }

    static let labels: [String: String] = [
        "files": "Read and change files in folders you choose", "clipboard": "Read, change and watch the clipboard",
        "accessibility": "Read selected text and control other apps", "microphone": "Use your microphone",
        "network": "Connect to the internet", "shell": "Run commands as your user", "ai": "Use your AI accounts and send prompts",
        "background": "Run while the plugin is enabled", "hotkeys": "Register global keyboard shortcuts",
        "notifications": "Send notifications", "launcher": "Add launcher items and answers",
        "windows": "Read the frontmost app and window", "secrets": "Save private credentials in Keychain"
    ]

    func approved(_ manifest: PluginManifestV2) -> Bool { grants[manifest.id]?.allows(manifest) == true }

    @MainActor func review(_ manifest: PluginManifestV2, force: Bool = false) async -> Bool {
        if approved(manifest), !force { return true }
        guard !reviewing.contains(manifest.id), force || !deniedThisSession.contains(manifest.id) else { return false }
        reviewing.insert(manifest.id)
        defer { reviewing.remove(manifest.id) }
        if presenting { await withCheckedContinuation { reviewQueue.append($0) } }
        presenting = true
        defer {
            if reviewQueue.isEmpty { presenting = false } else { reviewQueue.removeFirst().resume() }
        }
        let alert = NSAlert()
        alert.messageText = "Allow \(manifest.name)?"
        let source = FileManager.default.fileExists(atPath: manifest.directory.appendingPathComponent(PluginStoreClient.receiptName).path) ? "Store plugin" : "Developer plugin"
        var lines = [source + " · " + manifest.id]
        lines += manifest.requested.sorted().map { "• " + (Self.labels[$0] ?? $0) }
        if manifest.native != nil {
            lines += ["", "This plugin runs a separate, unsandboxed helper as you. It can access files and the network directly. Child helpers can use Nook’s macOS privacy (TCC) grants, including Accessibility and microphone access. macOS may also require permission for a helper’s identity. Only allow code you trust."]
        } else if manifest.requested.isEmpty { lines += ["Use Nook’s panel and its own saved settings."] }
        lines += ["", "You can revoke access in Settings → Tabs & Plugins. Revoking stops the helper."]
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "Allow"); alert.addButton(withTitle: "Don’t Allow")
        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            response = await withCheckedContinuation { continuation in alert.beginSheetModal(for: window) { continuation.resume(returning: $0) } }
        } else { response = alert.runModal() }
        guard response == .alertFirstButtonReturn else { deniedThisSession.insert(manifest.id); return false }
        var scopes = grants[manifest.id]?.fileScopes ?? []
        if manifest.requested.contains("files"), scopes.isEmpty {
            let panel = NSOpenPanel()
            panel.title = "Choose folders for \(manifest.name)"
            panel.message = "Host file APIs are limited to these folders and the plugin’s own data. The native helper is unsandboxed."
            panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = true
            guard panel.runModal() == .OK else { return false }
            scopes = panel.urls.map { $0.resolvingSymlinksInPath().path }
        }
        grants[manifest.id] = PluginPermissionGrant(permissions: manifest.requested, native: manifest.native != nil, fileScopes: scopes)
        deniedThisSession.remove(manifest.id)
        save()
        return true
    }

    func revoke(_ id: String) {
        grants.removeValue(forKey: id); deniedThisSession.insert(id); save()
        Features.shared.setTab(id, false)
        PluginEngine.shared.stop(id)
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(grants), forKey: key)
        NotificationCenter.default.post(name: .nookPluginPermissionsChanged, object: nil)
    }
}

extension Notification.Name {
    static let nookPluginPermissionsChanged = Notification.Name("nookPluginPermissionsChanged")
}

struct PluginPermissionsSection: View {
    let tab: TabItem
    @ObservedObject private var permissions = PluginPermissions.shared
    @State private var working = false
    private var manifest: PluginManifestV2? { tab.dir.flatMap { try? PluginManifestV2(directory: $0) } }
    var body: some View {
        if let manifest, manifest.apiVersion == 2 {
            Section("Permissions & Trust") {
                LabeledContent("Source", value: FileManager.default.fileExists(atPath: manifest.directory.appendingPathComponent(PluginStoreClient.receiptName).path) ? "Store · verified on install" : "Developer")
                ForEach(manifest.requested.sorted(), id: \.self) { permission in
                    Label(PluginPermissions.labels[permission] ?? permission, systemImage: permissions.approved(manifest) ? "checkmark.circle" : "circle")
                }
                if manifest.native != nil { Text("Runs a separate helper with your user privileges and Nook’s effective macOS privacy grants.").foregroundStyle(.secondary) }
                if let grant = permissions.grants[tab.id] {
                    ForEach(grant.fileScopes, id: \.self) { Text($0).font(.caption).textSelection(.enabled) }
                }
                HStack {
                    Button(permissions.approved(manifest) ? "Review Access…" : "Allow Access…") {
                        working = true
                        Task { @MainActor in _ = await permissions.review(manifest, force: true); working = false; PluginEngine.shared.reconcile() }
                    }.disabled(working)
                    if permissions.grants[tab.id] != nil { Button("Revoke Access", role: .destructive) { permissions.revoke(tab.id) } }
                }
            }
        }
    }
}
