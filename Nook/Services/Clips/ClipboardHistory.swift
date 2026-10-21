import AppKit
import ImageIO

/// Main-thread state; all disk writes and image conversion run on a serial utility queue.
final class ClipboardHistory: ObservableObject {
    static let shared = ClipboardHistory()
    @Published private(set) var entries: [ClipEntry] = []
    @Published var error: String?
    private(set) var isReady = false
    private(set) var directory: URL!
    private var imageDirectory: URL { directory.appendingPathComponent("Images", isDirectory: true) }
    private var indexURL: URL { directory.appendingPathComponent("history.json") }
    private let io = DispatchQueue(label: "com.yusuf.nook.clips.store", qos: .utility)
    private var timer: Timer?
    private var changeCount = 0
    private var generation = 0
    private var settingsObserver: NSObjectProtocol?
    private var settingsSignature = ""
    private var lastPrune = Date.distantPast

    func start() {
        guard directory == nil else { return }
        ClipPreferences.register()
        directory = Services.supportDir.appendingPathComponent("Clips", isDirectory: true)
        changeCount = NSPasteboard.general.changeCount // don't capture a pre-launch secret
        let root = directory!, images = imageDirectory, index = indexURL, version = generation
        io.async {
            do {
                try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
                let loaded: [ClipEntry]
                if FileManager.default.fileExists(atPath: index.path) {
                    loaded = try JSONDecoder().decode([ClipEntry].self, from: Data(contentsOf: index))
                } else { loaded = [] }
                // Recover image files left between a completed capture and an interrupted index write.
                let known = Set(loaded.filter { $0.kind == .image }.flatMap(\.urls).map(\.lastPathComponent))
                for url in try FileManager.default.contentsOfDirectory(at: images, includingPropertiesForKeys: nil)
                    where url.pathExtension == "png" && UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil && !known.contains(url.lastPathComponent) {
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                }
                DispatchQueue.main.async {
                    guard self.generation == version else { return }
                    self.entries = loaded.filter { $0.kind != .image || $0.paths.first.map { FileManager.default.fileExists(atPath: $0) } == true }
                    self.isReady = true
                    self.prune()
                    self.beginCapture()
                }
            } catch {
                DispatchQueue.main.async { self.fail("Couldn't load clipboard history: \(error.localizedDescription)") }
            }
        }
    }

    private func beginCapture() {
        let timer = Timer(timeInterval: 0.75, repeats: true) { [weak self] _ in self?.check() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        settingsSignature = signature
        settingsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.settingsSignature != self.signature else { return }
            self.settingsSignature = self.signature
            self.generation += 1 // discard queued captures when privacy settings change
            self.changeCount = NSPasteboard.general.changeCount
            self.prune()
        }
        changed()
    }

    private var signature: String {
        let d = UserDefaults.standard
        return "\(d.bool(forKey: ClipPreferences.enabled))|\(d.integer(forKey: ClipPreferences.days))|\(d.integer(forKey: ClipPreferences.maxItems))|\(d.string(forKey: ClipPreferences.ignoredApps) ?? "")"
    }

    private func check() {
        if Date().timeIntervalSince(lastPrune) > 60 { prune() }
        let board = NSPasteboard.general
        guard board.changeCount != changeCount else { return }
        changeCount = board.changeCount
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: ClipPreferences.enabled), Date() > LinkCatcher.ignoreClipboardUntil else { return }
        let app = NSWorkspace.shared.frontmostApplication
        guard !ClipPreferences.ignores(name: app?.localizedName ?? "", bundleID: app?.bundleIdentifier ?? "",
                                      list: defaults.string(forKey: ClipPreferences.ignoredApps) ?? ""),
              let snapshot = ClipCapture.read(board, source: app?.localizedName ?? "") else { return }
        let version = generation
        let images = imageDirectory
        io.async {
            var entry = snapshot.entry
            do {
                if let data = snapshot.image {
                    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                          let width = properties[kCGImagePropertyPixelWidth] as? Int,
                          let height = properties[kCGImagePropertyPixelHeight] as? Int,
                          Double(width) * Double(height) <= 40_000_000,
                          let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else { return }
                    let png = NSMutableData()
                    guard let destination = CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil) else { return }
                    CGImageDestinationAddImage(destination, image, nil)
                    guard CGImageDestinationFinalize(destination) else { return }
                    entry.fingerprint = "image:" + ClipEntry.hash(png as Data)
                    // Each queued capture owns its file, so discarding one cannot delete
                    // a newer capture of the same image after a concurrent Clear.
                    let url = images.appendingPathComponent(entry.id + ".png")
                    try (png as Data).write(to: url, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                    entry.paths = [url.path]
                }
                let captured = entry
                DispatchQueue.main.async {
                    guard self.generation == version else {
                        self.trashOwnedImages([captured], keeping: self.entries)
                        return
                    }
                    self.entries = ClipEntry.inserting(captured, into: self.entries)
                    self.trashOwnedImages([captured], keeping: self.entries) // duplicate image: retain the previous asset
                    self.prune()
                }
            } catch {
                DispatchQueue.main.async { self.fail("Couldn't save clipboard image: \(error.localizedDescription)") }
            }
        }
    }

    func prune() {
        lastPrune = Date()
        let defaults = UserDefaults.standard
        let kept = ClipEntry.retained(entries, days: defaults.integer(forKey: ClipPreferences.days), maxItems: defaults.integer(forKey: ClipPreferences.maxItems))
        let ids = Set(kept.map(\.id))
        trashOwnedImages(entries.filter { !ids.contains($0.id) }, keeping: kept)
        entries = kept
        changed()
    }

    func setPinned(_ id: String, _ pinned: Bool) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { throw ClipsError.missing }
        entries[index].pinned = pinned
        prune()
    }

    /// Explicit deletion trashes referenced files; retention and clear never touch originals.
    func delete(_ id: String, completion: @escaping (Error?) -> Void) {
        guard let entry = entries.first(where: { $0.id == id }) else { return completion(ClipsError.missing) }
        trash(entry.urls) { error in
            if error == nil {
                self.entries.removeAll { $0.id == id }
                self.changed()
            }
            completion(error)
        }
    }

    func clear() {
        generation += 1
        changeCount = NSPasteboard.general.changeCount
        trashOwnedImages(entries, keeping: [])
        entries = []
        error = nil
        isReady = true
        if timer == nil { beginCapture() }
        changed()
    }

    private func trashOwnedImages(_ removed: [ClipEntry], keeping: [ClipEntry]) {
        let protected = Set(keeping.flatMap(\.paths))
        let images = imageDirectory.standardizedFileURL
        let urls = Set(removed.filter { $0.kind == .image }.flatMap(\.urls)).filter {
            $0.deletingLastPathComponent().standardizedFileURL == images && !protected.contains($0.path)
        }
        trash(Array(urls)) { error in
            if let error { self.fail("An expired or removed image couldn't move to Trash: \(error.localizedDescription)") }
        }
    }

    private func trash(_ urls: [URL], completion: @escaping (Error?) -> Void) {
        io.async {
            var failure: Error?
            for url in urls where FileManager.default.fileExists(atPath: url.path) {
                do { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
                catch { failure = error; break }
            }
            let result = failure
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func changed() {
        guard directory != nil else { return }
        let entries = self.entries, url = indexURL
        io.async {
            do {
                try JSONEncoder().encode(entries).write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch {
                DispatchQueue.main.async { self.fail("Couldn't save clipboard history: \(error.localizedDescription)") }
            }
        }
        PluginEvents.emit("clips", [:], to: "clips")
    }

    private func fail(_ message: String) {
        error = message
        PluginEvents.emit("clips", [:], to: "clips")
    }
}

enum ClipsError: LocalizedError {
    case missing, noFile, accessibility, noTarget, clipboard, unavailable
    var errorDescription: String? {
        switch self {
        case .missing: "This item is no longer in history. Refresh and try again."
        case .noFile: "This item has no file to open or reveal."
        case .accessibility: "Allow Nook in System Settings → Privacy & Security → Accessibility to paste. The item can still be copied."
        case .noTarget: "Switch to the app you want to paste into, then reopen Clips."
        case .clipboard: "Couldn't put this item on the clipboard. Its file may have moved."
        case .unavailable: "Clipboard history is still loading. Try again shortly."
        }
    }
}
