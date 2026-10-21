import AppKit
import CoreServices
import QuickLookThumbnailing
import UniformTypeIdentifiers
import Vision

/// Indexes originals in place. No capture API, upload, or copy of a user's screenshots is involved.
final class ScreenCaptureIndex {
    static let shared = ScreenCaptureIndex()
    private(set) var entries: [ClipEntry] = []
    private(set) var error: String?
    private(set) var scanning = false
    private(set) var isReady = false
    private(set) var folder = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop")
    private var directory: URL!
    private var source: DispatchSourceFileSystemObject?
    private var refreshTimer: Timer?
    private var observer: NSObjectProtocol?
    private var pendingScan: DispatchWorkItem?
    private var scanAgain = false
    private var ocrRunning = false
    private var revision = 0
    private let io = DispatchQueue(label: "com.yusuf.nook.clips.index", qos: .utility)
    private let ocrQueue = DispatchQueue(label: "com.yusuf.nook.clips.ocr", qos: .utility)
    private let folderProvider: () -> URL
    private let ocrEnabled: () -> Bool
    private var cacheURL: URL { directory.appendingPathComponent("screenshots.json") }

    init(folderProvider: @escaping () -> URL = { ScreenCaptureIndex.configuredFolder() },
         ocrEnabled: @escaping () -> Bool = { UserDefaults.standard.bool(forKey: ClipPreferences.ocr) }) {
        self.folderProvider = folderProvider
        self.ocrEnabled = ocrEnabled
    }

    static func configuredFolder() -> URL {
        let override = UserDefaults.standard.string(forKey: ClipPreferences.folder)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let system = CFPreferencesCopyAppValue("location" as CFString, "com.apple.screencapture" as CFString) as? String
        let path = override.isEmpty ? (system ?? "~/Desktop") : override
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
    }

    func start(directory: URL) {
        guard self.directory == nil else { return }
        self.directory = directory
        let url = cacheURL
        io.async {
            let loaded = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([ClipEntry].self, from: $0) } ?? []
            DispatchQueue.main.async {
                let configured = self.folderProvider().standardizedFileURL.resolvingSymlinksInPath()
                self.entries = loaded.filter { $0.urls.first?.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path == configured.path }
                self.folder = configured // preserve the restored cache when the first watcher is installed
                self.refresh()
                self.observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
                    self?.refresh()
                }
                let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.refresh() }
                RunLoop.main.add(timer, forMode: .common)
                self.refreshTimer = timer
            }
        }
    }

    func refresh() {
        let desired = folderProvider().standardizedFileURL.resolvingSymlinksInPath()
        if desired != folder || source == nil {
            let changedFolder = desired != folder
            folder = desired
            revision += 1
            if changedFolder { entries = []; emit() }
            watch()
        }
        pendingScan?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.scan() }
        pendingScan = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: work)
    }

    private func watch() {
        source?.cancel()
        source = nil
        let descriptor = Darwin.open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete, .attrib], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            if source?.data.contains(.delete) == true || source?.data.contains(.rename) == true {
                self?.source?.cancel()
                self?.source = nil
            }
            self?.refresh()
        }
        source.setCancelHandler { Darwin.close(descriptor) }
        self.source = source
        source.resume()
    }

    private func scan() {
        guard !scanning else { scanAgain = true; return }
        scanning = true
        emit()
        let folder = self.folder, version = revision
        io.async {
            do {
                let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .creationDateKey, .contentModificationDateKey, .contentTypeKey, .fileSizeKey]
                let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
                var found: [ClipEntry] = []
                for url in urls {
                    guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true,
                          values.isSymbolicLink != true, (values.fileSize ?? 0) > 0,
                          let type = values.contentType, type.conforms(to: .image) || type.conforms(to: .movie),
                          Self.isCapture(url) else { continue }
                    let modified = values.contentModificationDate ?? .distantPast
                    // Screenshot tools write/rename in stages. The periodic rescan retries unfinished files.
                    guard modified < Date().addingTimeInterval(-2) else { continue }
                    var entry = ClipEntry(kind: type.conforms(to: .movie) ? .recording : .screenshot,
                                          paths: [url.path], date: values.creationDate ?? modified, source: "Screen Capture")
                    entry.id = "capture-" + ClipEntry.hash(Data(url.path.utf8))
                    entry.modifiedAt = modified
                    found.append(entry)
                }
                let captures = ClipEntry.sorted(found)
                DispatchQueue.main.async {
                    if version == self.revision {
                        let old = Dictionary(self.entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                        let pinned = Set(old.values.filter(\.pinned).map(\.id))
                        var unpinnedCount = 0
                        self.entries = captures.filter { item in
                            if pinned.contains(item.id) { return true }
                            unpinnedCount += 1
                            return unpinnedCount <= 2000
                        }.map { item in
                            var item = item
                            if let previous = old[item.id] {
                                item.pinned = previous.pinned
                                if previous.modifiedAt == item.modifiedAt { item.ocrText = previous.ocrText }
                            }
                            return item
                        }
                        self.error = nil
                        self.save()
                    }
                    self.finishedScan()
                }
            } catch {
                DispatchQueue.main.async {
                    if version == self.revision { self.error = "Couldn't read \(folder.path). Check the folder and Nook's Files & Folders permission. \(error.localizedDescription)"; self.emit() }
                    self.finishedScan()
                }
            }
        }
    }

    static func isCapture(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        let pattern = #"^(screen[ _-]?(shot|recording)|capture d[’']écran|enregistrement de l[’']écran|bildschirm(foto|aufnahme)|captura de pantalla|grabación de pantalla)"#
        if name.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil { return true }
        guard let item = MDItemCreate(kCFAllocatorDefault, url.path as CFString) else { return false }
        return (MDItemCopyAttribute(item, "kMDItemIsScreenCapture" as CFString) as? Bool) == true
    }

    private func finishedScan() {
        scanning = false
        isReady = true
        emit()
        if scanAgain { scanAgain = false; refresh() }
        recognizeNext()
    }

    private func recognizeNext() {
        guard !ocrRunning, ocrEnabled(),
              let entry = entries.first(where: { $0.kind == .screenshot && $0.ocrText == nil }), let url = entry.urls.first else { return }
        ocrRunning = true
        let version = revision
        ocrQueue.async {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            var text = ""
            do {
                try VNImageRequestHandler(url: url, options: [:]).perform([request])
                text = String((request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n").prefix(100_000))
            } catch { /* An unreadable/unsupported screenshot gets an empty cached result until it changes. */ }
            let recognized = text
            DispatchQueue.main.async {
                self.ocrRunning = false
                if version == self.revision, self.ocrEnabled(),
                   let index = self.entries.firstIndex(where: { $0.id == entry.id && $0.modifiedAt == entry.modifiedAt }) {
                    self.entries[index].ocrText = recognized
                    self.save()
                }
                self.recognizeNext()
            }
        }
    }

    func setPinned(_ id: String, _ pinned: Bool) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { throw ClipsError.missing }
        entries[index].pinned = pinned
        save()
    }

    func delete(_ id: String, completion: @escaping (Error?) -> Void) {
        guard let entry = entries.first(where: { $0.id == id }), let url = entry.urls.first else { return completion(ClipsError.missing) }
        revision += 1 // an in-flight scan must not reinsert the deleted file
        scanAgain = true
        io.async {
            do {
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
                DispatchQueue.main.async { self.entries.removeAll { $0.id == id }; self.save(); completion(nil) }
            } catch { DispatchQueue.main.async { completion(error) } }
        }
    }

    private func save() {
        let entries = self.entries, url = cacheURL
        io.async {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try JSONEncoder().encode(entries).write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch {
                DispatchQueue.main.async { self.error = "Couldn't cache screenshot search: \(error.localizedDescription)"; self.emit() }
            }
        }
        emit()
    }

    private func emit() { PluginEvents.emit("clips", [:], to: "clips") }
}

final class ClipsThumbnails {
    static let shared = ClipsThumbnails()
    private let cache = NSCache<NSString, NSData>()

    private init() { cache.totalCostLimit = 16 * 1024 * 1024 }

    func get(_ entry: ClipEntry, completion: @escaping (String?, String?) -> Void) {
        guard let url = entry.urls.first else { return completion(nil, nil) }
        let key = "\(url.path)|\(entry.modifiedAt?.timeIntervalSince1970 ?? 0)" as NSString
        if let data = cache.object(forKey: key) { return completion("data:image/jpeg;base64," + (data as Data).base64EncodedString(), nil) }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 240, height: 140), scale: 2, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, error in
            guard let representation,
                  let data = NSBitmapImageRep(cgImage: representation.cgImage).representation(using: .jpeg, properties: [.compressionFactor: 0.75]) else {
                return DispatchQueue.main.async { completion(nil, error?.localizedDescription) }
            }
            self.cache.setObject(data as NSData, forKey: key, cost: data.count)
            DispatchQueue.main.async { completion("data:image/jpeg;base64," + data.base64EncodedString(), nil) }
        }
    }
}
