import Foundation
import Darwin

/// A lexical gate: constructing or consulting it never inspects a protected folder.
/// Per-folder grants have no public, silent preflight API. Only a successful read in
/// response to Allow Access is remembered; merely entering a path is not consent.
struct FileSearchAccessPolicy: Equatable {
    static let requestedKey = "files.protectedFoldersRequested"
    static let grantedKey = "files.grantedFolders"
    let home: String
    let fullDiskAccess: Bool
    let granted: [String]
    let volumes: [String]

    init(home: String = NSHomeDirectory(), fullDiskAccess: Bool = false, granted: [String] = [], volumes: [String] = []) {
        let normalizedHome = FileIndexPath.lexical(home)
        self.home = normalizedHome
        self.fullDiskAccess = fullDiskAccess
        let requestable = ["Desktop", "Documents", "Downloads"].map { normalizedHome + "/" + $0 }
        self.granted = granted.map(FileIndexPath.lexical).filter { requestable.contains($0) }
        self.volumes = volumes.map(FileIndexPath.lexical)
    }
    var requestable: [String] { ["Desktop", "Documents", "Downloads"].map { home + "/" + $0 } }
    var protected: [String] {
        requestable + ["Pictures", "Movies", "Music", "Library"].map { home + "/" + $0 }
    }
    var exclusions: [String] {
        guard !fullDiskAccess else { return [] }
        return protected.filter { !granted.contains($0) } + volumes + ["/Volumes", "/Network", "/net"]
    }
    var needsAccess: Bool { !fullDiskAccess && requestable.contains { !granted.contains($0) } }
    func allows(_ path: String) -> Bool {
        let path = FileIndexPath.lexical(path)
        return !exclusions.contains { FileSearchPolicy.isInside(path, root: $0) }
    }
    /// Only the FDA sentinel is opened. Reading this database is *not* required, and
    /// a denied open is silent. Never use a Desktop/Documents existence/read probe.
    static func hasFullDiskAccess(home: String = NSHomeDirectory()) -> Bool {
        let fd = Darwin.open(home + "/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return false }
        Darwin.close(fd); return true
    }
    /// getfsstat(MNT_NOWAIT) reads the kernel mount table, without contacting a
    /// network server, mounting a volume, or opening its mount point. Unlike
    /// getmntinfo, caller-owned storage is safe across concurrent refreshes.
    static func protectedVolumes() -> [String] {
        let capacity = Int(getfsstat(nil, 0, MNT_NOWAIT)) + 8
        guard capacity > 8 else { return [] }
        var mounts = Array<statfs>(repeating: statfs(), count: capacity)
        let count = mounts.withUnsafeMutableBufferPointer { buffer in
            getfsstat(buffer.baseAddress, Int32(buffer.count * MemoryLayout<statfs>.stride), MNT_NOWAIT)
        }
        guard count > 0 else { return [] }
        return (0..<min(Int(count), mounts.count)).compactMap { index in
            var info = mounts[index]
            guard info.f_flags & UInt32(MNT_LOCAL) == 0 || info.f_flags & UInt32(MNT_REMOVABLE) != 0 else { return nil }
            return withUnsafePointer(to: &info.f_mntonname) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
        }
    }

    static func current(defaults: PluginDefaults = .standard, home: String = NSHomeDirectory()) -> Self {
        let requested = defaults.bool(forKey: requestedKey)
        return Self(home: home, fullDiskAccess: hasFullDiskAccess(home: home),
                    granted: requested ? defaults.stringArray(forKey: grantedKey) ?? [] : [], volumes: protectedVolumes())
    }
    /// Validate roots one component at a time. Never resolve a symlink into an
    /// unapproved folder (including a symlink in an additional root's parent).
    func safeRoot(_ raw: String) -> String? { safePath(raw, directory: true) }
    func safeFile(_ raw: String) -> String? { safePath(raw, directory: false) }
    private func safePath(_ raw: String, directory: Bool) -> String? {
        let path = FileIndexPath.lexical(raw)
        guard allows(path) else { return nil }
        if !fullDiskAccess && Self.protectedVolumes().contains(where: { FileSearchPolicy.isInside(path, root: FileIndexPath.lexical($0)) }) { return nil }
        let parts = path.split(separator: "/")
        var prefix = ""
        for (index, component) in parts.enumerated() {
            prefix += "/" + component
            guard allows(prefix) else { return nil }
            var info = stat()
            guard lstat(prefix, &info) == 0 else { return nil }
            let type = info.st_mode & S_IFMT
            let lastFile = !directory && index == parts.count - 1
            guard type == S_IFDIR || (lastFile && type == S_IFREG) else { return nil }
        }
        return path
    }
}
