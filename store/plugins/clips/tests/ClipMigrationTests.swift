import Foundation
import Darwin
@main enum ClipMigrationTests {
    static func main() throws {
        let root = PluginRuntime.data
        precondition(root.path.hasPrefix("/tmp/") || root.path.hasPrefix("/private/tmp/"))
        let old = root.appendingPathComponent("Legacy/Clips"), images = old.appendingPathComponent("Images")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let image = images.appendingPathComponent("test.png")
        try Data([1, 2, 3]).write(to: image)
        let entry = ClipEntry(kind: .image, paths: [image.path], pinned: true)
        let bytes = try JSONEncoder().encode([entry])
        try bytes.write(to: old.appendingPathComponent("history.json"))
        try ClipMigration.run(legacy: old, preferences: ["clips.days": 90, "features.enabled.screenshots": false])
        let migrated = try JSONDecoder().decode([ClipEntry].self, from: Data(contentsOf: root.appendingPathComponent("Clips/history.json")))
        precondition(migrated[0].pinned && migrated[0].id == entry.id)
        precondition(migrated[0].paths == [root.appendingPathComponent("Clips/Images/test.png").path])
        let newImage = try Data(contentsOf: URL(fileURLWithPath: migrated[0].paths[0]))
        precondition(newImage == Data([1, 2, 3]))
        let legacyBytes = try Data(contentsOf: old.appendingPathComponent("history.json"))
        precondition(legacyBytes == bytes)
        precondition(PluginDefaults.standard.integer(forKey: "clips.days") == 90)
        precondition(!Features.shared.enabled("screenshots"))
        try ClipMigration.run(legacy: old, preferences: ["clips.days": 3])
        precondition(PluginDefaults.standard.integer(forKey: "clips.days") == 90)
        guard let resolved = realpath(root.path, nil) else { fatalError("Fixture root missing") }
        let physical = String(cString: resolved); free(resolved)
        let scoped = URL(fileURLWithPath: physical).appendingPathComponent("Scoped")
        try FileManager.default.createDirectory(at: scoped, withIntermediateDirectories: true)
        precondition(CaptureFolderScope.allows(scoped, scopes: [scoped.path]))
        precondition(!CaptureFolderScope.allows(scoped, scopes: []))
        let link = scoped.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.resolvingSymlinksInPath())
        precondition(!CaptureFolderScope.allows(link, scopes: [scoped.path]))
        precondition(!CaptureFolderScope.allows(URL(fileURLWithPath: scoped.path + "-other"), scopes: [scoped.path]))
        print("PASS: clipboard images, pins, stable IDs and screenshot choices migrate without changing legacy files")
    }
}
