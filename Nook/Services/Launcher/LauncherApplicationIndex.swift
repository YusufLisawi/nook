import AppKit
import Combine
import CoreServices
import CryptoKit

struct LauncherApplication: Codable, Identifiable {
    let path: String
    let name: String
    let bundleID: String
    var id: String { "app:" + path }
}

/// All filesystem enumeration, bundle reads and icon rendering use a serial utility queue.
/// Spotlight and FSEvents lifetimes stay on the main run loop.
final class LauncherApplicationIndex: ObservableObject {
    static let shared = LauncherApplicationIndex()
    @Published private(set) var applications: [LauncherApplication] = []
    @Published private(set) var gathering = true
    @Published private(set) var diagnostic: String?
    @Published private(set) var runningPaths = Set<String>()
    private let queue = DispatchQueue(label: "nook.launcher.index", qos: .utility)
    private var query: NSMetadataQuery?
    private var stream: FSEventStreamRef?
    private var observers: [NSObjectProtocol] = []
    private var pending: DispatchWorkItem?
    private var spotlightPaths: [String] = []
    private var icons: [String: NSImage] = [:]
    private var iconWaiters: [String: [(NSImage?) -> Void]] = [:]
    private var generation = 0
    private let roots = ["/Applications", "/System/Applications", "/System/Applications/Utilities", NSHomeDirectory() + "/Applications"]
    private let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("com.yusuf.nook/Launcher", isDirectory: true)

    func start() {
        guard query == nil else { return }
        updateRunning()
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.updateRunning(); self?.scheduleRefresh()
            })
        }
        let file = cache.appendingPathComponent("applications.json")
        queue.async { [weak self] in
            let cached = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([LauncherApplication].self, from: $0) } ?? []
            DispatchQueue.main.async {
                guard let self else { return }
                if !cached.isEmpty {
                    let cachedPaths = Set(cached.map(\.path))
                    self.applications = cached.filter { $0.bundleID != Bundle.main.bundleIdentifier }
                        + self.applications.filter { !cachedPaths.contains($0.path) }
                }
                self.refresh()
            }
        }
        let query = NSMetadataQuery()
        query.predicate = NSPredicate(format: "kMDItemContentType == %@", "com.apple.application-bundle")
        query.searchScopes = [NSMetadataQueryLocalComputerScope]
        query.notificationBatchingInterval = 1
        for name in [NSNotification.Name.NSMetadataQueryDidFinishGathering, NSNotification.Name.NSMetadataQueryDidUpdate] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: query, queue: .main) { [weak self] _ in
                guard let self, let query = self.query else { return }
                query.disableUpdates()
                self.spotlightPaths = query.results.compactMap { ($0 as? NSMetadataItem)?.value(forAttribute: NSMetadataItemPathKey) as? String }
                query.enableUpdates()
                self.scheduleRefresh()
            })
        }
        self.query = query
        if !query.start() { diagnostic = "Spotlight is unavailable. Searching the standard Applications folders." }
        watch()
    }

    private func updateRunning() {
        let running = NSWorkspace.shared.runningApplications
        runningPaths = Set(running.compactMap { $0.bundleURL?.standardizedFileURL.path })
        if applications.isEmpty {
            applications = running.compactMap { app in
                guard app.activationPolicy == .regular, let path = app.bundleURL?.standardizedFileURL.path else { return nil }
                return LauncherApplication(path: path, name: app.localizedName ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
                                           bundleID: app.bundleIdentifier ?? "")
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    private func scheduleRefresh() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func refresh() {
        generation += 1
        let token = generation, roots = roots, extra = spotlightPaths + Array(runningPaths), file = cache.appendingPathComponent("applications.json")
        queue.async { [weak self] in
            let manager = FileManager.default
            var paths = Set(extra.filter { $0.hasSuffix(".app") })
            for root in roots {
                guard let enumerator = manager.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
                for case let url as URL in enumerator where url.pathExtension.lowercased() == "app" { paths.insert(url.standardizedFileURL.path) }
            }
            let apps = paths.compactMap { path -> LauncherApplication? in
                guard manager.fileExists(atPath: path), let bundle = Bundle(path: path),
                      bundle.bundleIdentifier != Bundle.main.bundleIdentifier,
                      bundle.infoDictionary?["LSBackgroundOnly"] as? Bool != true else { return nil }
                let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                    ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                    ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
                return LauncherApplication(path: path, name: name, bundleID: bundle.bundleIdentifier ?? "")
            }.sorted { ($0.name.localizedLowercase, $0.path) < ($1.name.localizedLowercase, $1.path) }
            try? manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(apps) { try? data.write(to: file, options: .atomic) }
            DispatchQueue.main.async {
                guard let self, token == self.generation else { return }
                self.applications = apps
                self.gathering = false
            }
        }
    }

    func icon(for path: String, completion: @escaping (NSImage?) -> Void) {
        if let icon = icons[path] { completion(icon); return }
        if iconWaiters[path] != nil { iconWaiters[path]?.append(completion); return }
        iconWaiters[path] = [completion]
        let cache = cache
        queue.async { [weak self] in
            // Include bundle modification time so an updated app doesn't keep an obsolete icon.
            let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let key = SHA256.hash(data: Data((path + String(modified)).utf8)).map { String(format: "%02x", $0) }.joined()
            let url = cache.appendingPathComponent(key + ".png")
            var image = NSImage(contentsOf: url)
            if image == nil {
                let original = NSWorkspace.shared.icon(forFile: path)
                if let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8,
                                                  samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                   let context = NSGraphicsContext(bitmapImageRep: bitmap) {
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = context
                    original.draw(in: NSRect(x: 0, y: 0, width: 64, height: 64))
                    NSGraphicsContext.restoreGraphicsState()
                    if let data = bitmap.representation(using: .png, properties: [:]) {
                        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
                        try? data.write(to: url, options: .atomic)
                        image = NSImage(data: data)
                    }
                }
            }
            let result = image
            DispatchQueue.main.async {
                guard let self else { return }
                self.icons[path] = result
                let waiters = self.iconWaiters.removeValue(forKey: path) ?? []
                waiters.forEach { $0(result) }
            }
        }
    }

    private func watch() {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<LauncherApplicationIndex>.fromOpaque(info).takeUnretainedValue().scheduleRefresh()
        }
        stream = FSEventStreamCreate(nil, callback, &context, roots as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1,
                                     FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes))
        if let stream { FSEventStreamSetDispatchQueue(stream, .main); FSEventStreamStart(stream) }
    }

    deinit {
        query?.stop()
        pending?.cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer); NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
    }
}
