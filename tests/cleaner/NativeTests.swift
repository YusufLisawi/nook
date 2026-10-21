import Foundation

@main
struct CleanerTests {
    static func main() throws {
        let files = FileManager.default
        let home = URL(fileURLWithPath: "/tmp/nook-cleaner-native-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: home) } // Only generated /tmp fixtures.
        func file(_ relative: String) throws -> URL {
            let url = home.appendingPathComponent(relative)
            try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("cache contents".utf8).write(to: url)
            return url
        }
        let allowed = try file("Library/Caches/allowed/cache").deletingLastPathComponent()
        let blocked = try file("Library/Caches/blocked/cache").deletingLastPathComponent()
        try files.setAttributes([.posixPermissions: 0o000], ofItemAtPath: blocked.path)
        defer { try? files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path) }
        let unreadableFile = try file("Library/Caches/unreadable-file")
        try files.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadableFile.path)
        defer { try? files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unreadableFile.path) }
        _ = try file("Library/Caches/partial/readable")
        let nested = try file("Library/Caches/partial/protected/private").deletingLastPathComponent()
        try files.setAttributes([.posixPermissions: 0o000], ofItemAtPath: nested.path)
        defer { try? files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: nested.path) }
        let external = try file("outside-cache/keep")
        let link = home.appendingPathComponent("Library/Caches/link")
        try files.createSymbolicLink(at: link, withDestinationURL: external.deletingLastPathComponent())
        _ = try file("Library/Caches/com.apple.keep/cache")
        _ = try file("Library/Caches/Yarn/keep")
        let fakeTrash = home.appendingPathComponent(".Trash", isDirectory: true)
        try files.createDirectory(at: fakeTrash, withIntermediateDirectories: true)
        // Write/search are sufficient for the fake destination; no component should try to list it.
        try files.setAttributes([.posixPermissions: 0o300], ofItemAtPath: fakeTrash.path)
        defer { try? files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeTrash.path) }
        // Inject only the final operation. All eligibility, permissions and measurement are production code.
        // Tests never invoke FileManager.trashItem or touch the user's real Trash.
        let engine = CleanerEngine(home: home) { item in
            precondition(item.resolvingSymlinksInPath().path.hasPrefix(home.resolvingSymlinksInPath().path + "/"))
            try files.moveItem(at: item, to: fakeTrash.appendingPathComponent(UUID().uuidString))
        }
        let first = try engine.clean(category: "caches", days: 60)
        precondition(first.moved == 1 && first.bytes > 0 && first.skipped == 4 && first.protectedCount == 3 && first.failed == 0)
        precondition(!files.fileExists(atPath: allowed.path) && files.fileExists(atPath: blocked.path))
        precondition(files.fileExists(atPath: external.path) && files.fileExists(atPath: link.path))
        // A denied Trash operation must leave the candidate and still move the next accessible sibling.
        _ = try file("Library/Logs/denied/log")
        _ = try file("Library/Logs/allowed/log")
        let partiallyDenied = CleanerEngine(home: home) { item in
            if item.lastPathComponent == "denied" { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM)) }
            try files.moveItem(at: item, to: fakeTrash.appendingPathComponent(UUID().uuidString))
        }
        let logs = try partiallyDenied.clean(category: "logs", days: 60)
        precondition(logs.moved == 1 && logs.skipped == 1 && logs.protectedCount == 1 && logs.failed == 0)
        precondition(files.fileExists(atPath: home.appendingPathComponent("Library/Logs/denied/log").path))
        let fullDisk = CleanerEngine(home: home) { _ in throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)) }
        let ioFailure = try fullDisk.clean(category: "logs", days: 60)
        precondition(ioFailure.failed == 1 && ioFailure.skipped == 0 && ioFailure.moved == 0)
        try files.setAttributes([.posixPermissions: 0o000], ofItemAtPath: home.appendingPathComponent("Library/Logs").path)
        let inaccessibleRoot = try engine.clean(category: "logs", days: 60)
        precondition(inaccessibleRoot.skipped == 1 && inaccessibleRoot.protectedCount == 1 && inaccessibleRoot.failed == 0)
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.appendingPathComponent("Library/Logs").path)
        let old = try file("Downloads/old")
        try files.setAttributes([.modificationDate: Date().addingTimeInterval(-90 * 86400)], ofItemAtPath: old.path)
        let recent = try file("Downloads/recent")
        _ = try file("Downloads/directory/keep")
        let downloads = try engine.clean(category: "downloads", days: 60)
        precondition(downloads.moved == 1 && files.fileExists(atPath: recent.path))
        // One symlinked package root cannot redirect cleanup or abort other package roots.
        try files.createDirectory(at: home.appendingPathComponent(".npm"), withIntermediateDirectories: true)
        try files.createSymbolicLink(at: home.appendingPathComponent(".npm/_cacache"), withDestinationURL: external.deletingLastPathComponent())
        _ = try file(".bun/install/cache/package")
        let packages = try engine.clean(category: "packages", days: 60)
        precondition(packages.moved == 2 && packages.skipped == 1 && packages.protectedCount == 0)
        precondition(files.fileExists(atPath: external.path))
        do { _ = try engine.clean(category: "../outside-cache", days: 60); preconditionFailure("Accepted arbitrary root") } catch {}
        // A home symlink itself is also rejected.
        let alias = home.appendingPathComponent("alias")
        try files.createSymbolicLink(at: alias, withDestinationURL: home)
        let unsafe = try CleanerEngine(home: alias, trash: { _ in preconditionFailure("Followed home symlink") }).clean(category: "logs", days: 60)
        precondition(unsafe.moved == 0 && unsafe.skipped == 1)
        print("PASS: native fake-home cleanup, unreadable and denied siblings, symlink safety, cache exclusions, download age, fixed roots")
    }
}
