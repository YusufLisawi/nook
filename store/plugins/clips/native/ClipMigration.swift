import Foundation

enum ClipMigration {
    static func run(legacy: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Nook/Clips"), preferences: [String: Any]? = nil) throws {
        PluginDefaults.standard.migrate(prefixes: ["clips.", "features.enabled.clipboard", "features.enabled.screenshots"], legacy: preferences)
        if let old = PluginDefaults.standard.object(forKey: "features.enabled.screenshots") as? Bool,
           PluginDefaults.standard.object(forKey: "capture.screenshots") == nil { PluginDefaults.standard.set(old, forKey: "capture.screenshots") }
        let old = legacy
        guard !PluginDefaults.standard.bool(forKey: "history.migrated") else { return }
        let destination = PluginRuntime.data.appendingPathComponent("Clips")
        // Copy first; rewrite only the private index. Originals and their paths are never mutated.
        try PluginRuntime.copyLegacy(old, to: destination)
        let history = destination.appendingPathComponent("history.json")
        if let bytes = try? Data(contentsOf: history) {
            var entries = try JSONDecoder().decode([ClipEntry].self, from: bytes)
            for i in entries.indices where entries[i].kind == .image {
                entries[i].paths = entries[i].paths.map { $0.hasPrefix(old.path + "/Images/") ? destination.appendingPathComponent("Images/" + URL(fileURLWithPath: $0).lastPathComponent).path : $0 }
            }
            try JSONEncoder().encode(entries).write(to: history, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: history.path)
        }
        PluginDefaults.standard.set(true, forKey: "history.migrated")
    }
}
