import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

enum FileSearchError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

/// Bounded reads and thumbnail generation stay off the search path. No file contents are persisted.
final class FileSearchPreview {
    private let cache = NSCache<NSString, NSDictionary>()
    private let worker = DispatchQueue(label: "com.yusuf.nook.files.preview", qos: .userInitiated)

    init() { cache.countLimit = 24; cache.totalCostLimit = 8 * 1024 * 1024 }

    static func fileURL(_ path: String) throws -> URL {
        guard path.hasPrefix("/") || path.hasPrefix("~/"), !path.contains("\0") else { throw FileSearchError.message("Choose an absolute file path.") }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { throw FileSearchError.message("This file moved or is no longer available. Search again.") }
        return url
    }

    func load(_ url: URL, reply: @escaping (Any?, String?) -> Void) {
        worker.async { [weak self] in
            guard let self else { return }
            do {
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .contentTypeKey, .isDirectoryKey, .isRegularFileKey, .isReadableKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
                let modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0
                let key = "\(url.path):\(modified):\(values.fileSize ?? 0)" as NSString
                if let stored = self.cache.object(forKey: key) { DispatchQueue.main.async { reply(stored, nil) }; return }
                var payload: [String: Any] = ["path": url.path, "name": url.lastPathComponent, "size": values.fileSize ?? 0,
                                            "kind": values.contentType?.localizedDescription ?? (values.isDirectory == true ? "Folder" : "File"), "modified": modified]
                let remote = values.isUbiquitousItem == true && values.ubiquitousItemDownloadingStatus != .current
                if remote {
                    payload["notice"] = "Download this file in Finder to preview it."
                    DispatchQueue.main.async { reply(payload, nil) }; return
                }
                if values.isReadable == false { throw FileSearchError.message("Nook can't read this file. Check its permissions in Finder.") }
                if values.isRegularFile == true && Self.isText(url, type: values.contentType) {
                    let text = try Self.readText(url)
                    if let text { payload["text"] = text; payload["truncated"] = (values.fileSize ?? 0) > Self.textLimit }
                }
                if values.isDirectory == true || payload["text"] != nil {
                    DispatchQueue.main.async { self.finish(payload, key: key, reply: reply) }; return
                }
                DispatchQueue.main.async { self.thumbnail(url, payload: payload, key: key, reply: reply) }
            } catch { DispatchQueue.main.async { reply(nil, error.localizedDescription) } }
        }
    }

    static let textLimit = 20 * 1024

    static func isText(_ url: URL, type: UTType?) -> Bool {
        type?.conforms(to: .text) == true || type?.conforms(to: .sourceCode) == true ||
        ["json", "yaml", "yml", "toml", "md", "markdown", "log", "conf", "ini", "env", "sh", "zsh", "bash", "gitignore", "csv", "sql", "swift", "rs", "ts", "tsx", "jsx", "lock"].contains(url.pathExtension.lowercased()) ||
        ["makefile", "dockerfile", ".gitignore", ".env"].contains(url.lastPathComponent.lowercased())
    }

    static func readText(_ url: URL) throws -> String? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: textLimit) ?? Data()
        if data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]) { return String(data: data, encoding: .utf16) }
        guard !data.contains(0) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        let controls = text.unicodeScalars.filter { $0.value < 32 && ![9, 10, 13].contains($0.value) }.count
        return controls > max(2, text.count / 100) ? nil : text
    }

    private func finish(_ payload: [String: Any], key: NSString, reply: @escaping (Any?, String?) -> Void) {
        let cost = (payload["thumbnail"] as? String)?.utf8.count ?? (payload["text"] as? String)?.utf8.count ?? 256
        cache.setObject(payload as NSDictionary, forKey: key, cost: cost)
        reply(payload, nil)
    }

    private func thumbnail(_ url: URL, payload: [String: Any], key: NSString, reply: @escaping (Any?, String?) -> Void) {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 260, height: 180), scale: 2, representationTypes: .all)
        var completed = false // accessed on the main queue only
        let finish: (String?) -> Void = { [weak self] dataURL in
            guard !completed else { return }; completed = true
            var result = payload
            if let dataURL { result["thumbnail"] = dataURL }
            else { result["notice"] = "Press Space for Quick Look." }
            self?.finish(result, key: key, reply: reply)
        }
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { thumbnail, _ in
            let data = thumbnail.flatMap { NSBitmapImageRep(cgImage: $0.cgImage).representation(using: .png, properties: [:]) }
            let url = data.map { "data:image/png;base64," + $0.base64EncodedString() }
            DispatchQueue.main.async { finish(url) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            guard !completed else { return }
            QLThumbnailGenerator.shared.cancel(request)
            finish(nil)
        }
    }
}
