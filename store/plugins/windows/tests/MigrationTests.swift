import Foundation
@main enum MigrationTests {
    static func main() throws {
        let root = PluginRuntime.data
        precondition(root.path.hasPrefix("/tmp/") || root.path.hasPrefix("/private/tmp/"))
        let defaults = PluginDefaults.standard
        defaults.migrate(prefixes: ["fixture."], legacy: ["fixture.count": 42, "fixture.bytes": Data([0, 1, 255]), "other.key": "ignore"])
        precondition(defaults.integer(forKey: "fixture.count") == 42 && defaults.data(forKey: "fixture.bytes") == Data([0, 1, 255]))
        precondition(defaults.object(forKey: "other.key") == nil)
        defaults.set(17, forKey: "fixture.count")
        defaults.migrate(prefixes: ["fixture."], legacy: ["fixture.count": 99])
        precondition(defaults.integer(forKey: "fixture.count") == 17, "Migration must never overwrite subsequent edits")
        let restored = PluginDefaults()
        precondition(restored.integer(forKey: "fixture.count") == 17, "Preferences live in the plugin data directory")
        let source = root.appendingPathComponent("OldCache"), destination = root.appendingPathComponent("NewCache")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let file = source.appendingPathComponent("index.bin")
        try Data([2, 3, 4]).write(to: file)
        try PluginRuntime.copyLegacy(source, to: destination)
        try Data([9]).write(to: file)
        try PluginRuntime.copyLegacy(source, to: destination)
        let copied = try Data(contentsOf: destination.appendingPathComponent("index.bin"))
        precondition(copied == Data([2, 3, 4]))
        let original = try Data(contentsOf: file)
        precondition(original == Data([9]), "Legacy data is read-only")
        let link = source.appendingPathComponent("redirect")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        let rejected = root.appendingPathComponent("RejectedCache")
        do { try PluginRuntime.copyLegacy(source, to: rejected); fatalError("Symlinked migration must be refused") }
        catch { precondition(!FileManager.default.fileExists(atPath: rejected.path)) }
        let group = DispatchGroup()
        for worker in 0..<4 {
            group.enter(); DispatchQueue.global().async {
                for value in 0..<10 { defaults.set(value, forKey: "worker.\(worker)"); _ = defaults.integer(forKey: "worker.\(worker)") }
                group.leave()
            }
        }
        group.wait()
        for worker in 0..<4 { precondition(defaults.integer(forKey: "worker.\(worker)") == 9) }
        print("PASS: private preferences/data migration, binary settings, prefix isolation, restart persistence and idempotence")
    }
}
