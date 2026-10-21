import Foundation
import Darwin

/// Check the lexical grant before touching a path, then refuse every symlink component.
enum CaptureFolderScope {
    static func allows(_ url: URL, scopes: [String]) -> Bool {
        // URL.standardizedFileURL can rewrite /private/tmp to /tmp and inspect aliases.
        // Normalize dot components lexically before any filesystem operation.
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.contains("\0") else { return false }
        var parts: [Substring] = []
        for part in url.path.split(separator: "/") {
            if part == "." { continue }
            if part == ".." { if !parts.isEmpty { parts.removeLast() } }
            else { parts.append(part) }
        }
        let path = "/" + parts.joined(separator: "/")
        guard scopes.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else { return false }
        var prefix = ""
        for component in path.split(separator: "/") {
            prefix += "/" + component
            var info = stat()
            guard lstat(prefix, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return false }
        }
        return true
    }
}
