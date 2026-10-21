import Foundation
import Darwin

/// Only immediate children of these roots are candidates. Keep in sync with Plugins/cleaner/shell.js.
struct CleanerEngine {
    static let roots: [String: [String]] = [
        "caches": ["Library/Caches"], "logs": ["Library/Logs"],
        "derived": ["Library/Developer/Xcode/DerivedData"],
        "devices": ["Library/Developer/Xcode/iOS DeviceSupport"],
        "simulators": ["Library/Developer/CoreSimulator/Caches"],
        "packages": [".npm/_cacache", ".bun/install/cache", "Library/pnpm/store",
                     "Library/Caches/Yarn", "Library/Caches/pip", "Library/Caches/CocoaPods", ".gradle/caches"],
        "downloads": ["Downloads"]
    ]

    struct Result {
        var bytes: Int64 = 0
        var moved = 0
        var skipped = 0
        var protectedCount = 0
        var failed = 0
        var payload: [String: Any] {
            ["bytes": bytes, "moved": moved, "skipped": skipped, "protectedCount": protectedCount, "failed": failed]
        }
    }

    private enum SafetyError: Error { case unsafe, missing }
    private let home: URL
    private let trash: (URL) throws -> Void
    private let files = FileManager.default

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
         trash: @escaping (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) {
        self.home = home.standardizedFileURL
        self.trash = trash
    }

    func clean(category: String, days: Int, now: Date = Date()) throws -> Result {
        guard let roots = Self.roots[category] else {
            throw NSError(domain: "NookCleaner", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unknown cleanup category."])
        }
        let cutoff = now.addingTimeInterval(-Double(min(365, max(7, days))) * 86400)
        var result = Result()
        for relative in roots {
            let root: URL
            let items: [URL]
            do {
                root = try safeRoot(relative)
                items = try files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            } catch SafetyError.missing { continue }
            catch SafetyError.unsafe { result.skipped += 1; continue }
            catch {
                if Self.isPermission(error) {
                    result.skipped += 1; result.protectedCount += 1
                } else { result.failed += 1 }
                continue
            }
            for item in items {
                if category == "caches", Self.excludedCache(item.lastPathComponent) { continue }
                do {
                    let before = try info(item)
                    guard before.st_mode & S_IFMT != S_IFLNK else { throw SafetyError.unsafe }
                    if category == "downloads", !eligibleDownload(before, cutoff: cutoff) { continue }
                    guard files.isReadableFile(atPath: item.path),
                          before.st_mode & S_IFMT != S_IFDIR || files.isExecutableFile(atPath: item.path) else {
                        throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
                    }
                    // du -P never follows symlinks. An unreadable subtree leaves this entire candidate intact.
                    guard let bytes = try measure(item) else {
                        result.skipped += 1; result.protectedCount += 1; continue
                    }
                    // Revalidate the fixed root, identity and age immediately before FileManager's Trash operation.
                    _ = try safeRoot(relative)
                    let after = try info(item)
                    guard before.st_dev == after.st_dev, before.st_ino == after.st_ino,
                          after.st_mode & S_IFMT != S_IFLNK else { throw SafetyError.unsafe }
                    if category == "downloads", !eligibleDownload(after, cutoff: cutoff) { continue }
                    try trash(item)
                    result.bytes += bytes
                    result.moved += 1
                } catch SafetyError.missing { continue } // App removed its own cache during this run.
                catch SafetyError.unsafe { result.skipped += 1 }
                catch {
                    if Self.isPermission(error) {
                        result.skipped += 1; result.protectedCount += 1
                    } else {
                        result.failed += 1
                    }
                }
            }
        }
        return result
    }

    private func info(_ url: URL) throws -> stat {
        var value = stat()
        guard lstat(url.path, &value) == 0 else {
            if errno == ENOENT { throw SafetyError.missing }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return value
    }

    private func safeRoot(_ relative: String) throws -> URL {
        guard home.path.hasPrefix("/"), home.path != "/" else { throw SafetyError.unsafe }
        var cursor = home
        // Check the home itself as well as every component beneath it, without following symlinks.
        for component in [""] + relative.split(separator: "/").map(String.init) {
            if !component.isEmpty { cursor.appendPathComponent(component, isDirectory: true) }
            let value = try info(cursor)
            guard value.st_mode & S_IFMT == S_IFDIR else { throw SafetyError.unsafe }
            guard files.isReadableFile(atPath: cursor.path), files.isExecutableFile(atPath: cursor.path) else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
            }
        }
        return cursor
    }

    private func eligibleDownload(_ value: stat, cutoff: Date) -> Bool {
        value.st_mode & S_IFMT == S_IFREG && Double(value.st_mtimespec.tv_sec) < cutoff.timeIntervalSince1970
    }

    private func measure(_ url: URL) throws -> Int64? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        process.arguments = ["-skP", url.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 120, execute: timeout)
        defer { timeout.cancel() }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let prefix = String(decoding: data, as: UTF8.self).split(separator: "\t", maxSplits: 1).first,
              let kibibytes = Int64(prefix), kibibytes >= 0, kibibytes <= Int64.max / 1024 else { return nil }
        return kibibytes * 1024
    }

    private static func excludedCache(_ name: String) -> Bool {
        name.hasPrefix("com.apple.") || ["Yarn", "yarn", "pip", "CocoaPods", "cocoapods", "Homebrew", "homebrew"].contains(name)
    }

    private static func isPermission(_ error: Error) -> Bool {
        let value = error as NSError
        if value.domain == NSPOSIXErrorDomain { return [Int(EACCES), Int(EPERM), Int(EROFS)].contains(value.code) }
        if value.domain == NSCocoaErrorDomain,
           [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(value.code) { return true }
        if let underlying = value.userInfo[NSUnderlyingErrorKey] as? Error { return isPermission(underlying) }
        return false
    }
}
