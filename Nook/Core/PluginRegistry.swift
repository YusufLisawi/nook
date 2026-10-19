import Foundation

struct TabItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case native
        case web(dir: URL, entry: String)
    }

    let id: String
    let name: String
    let symbol: String
    let order: Int
    let height: CGFloat
    let kind: Kind
    let icon: URL?
}

/// Lists native tabs plus folder plugins (bundled + ~/Library/Application Support/Nook/Plugins), and hot-reloads on change.
final class PluginRegistry: ObservableObject {
    static let defaultHeight: CGFloat = 210
    static let maxHeight: CGFloat = 400

    static var userDir: URL { Services.supportDir.appendingPathComponent("Plugins", isDirectory: true) }
    static var bundledDir: URL? { Bundle.main.resourceURL?.appendingPathComponent("Plugins", isDirectory: true) }

    static let nativeTabs: [TabItem] = [
        TabItem(id: "home", name: "Home", symbol: "house.fill", order: 10, height: defaultHeight, kind: .native, icon: nil),
        TabItem(id: "shelf", name: "Shelf", symbol: "tray.full.fill", order: 30, height: defaultHeight, kind: .native, icon: nil),
        TabItem(id: "scratch", name: "Scratch", symbol: "square.and.pencil", order: 35, height: defaultHeight, kind: .native, icon: nil),
        TabItem(id: "timers", name: "Timers", symbol: "timer", order: 80, height: defaultHeight, kind: .native, icon: nil),
        TabItem(id: "calendar", name: "Calendar", symbol: "calendar", order: 90, height: defaultHeight, kind: .native, icon: nil),
    ]

    @Published private(set) var tabs: [TabItem] = nativeTabs
    /// Bumps whenever a plugin file changes, so web views reload.
    @Published private(set) var revision = 0

    private var stream: FSEventStreamRef?

    private struct Manifest: Decodable {
        var id: String
        var name: String
        var symbol: String?
        var icon: String?
        var entry: String?
        var order: Int?
        var height: Double?
    }

    func start() {
        try? FileManager.default.createDirectory(at: Self.userDir, withIntermediateDirectories: true)
        reload()
        watch()
    }

    func reload() {
        var byID: [String: TabItem] = [:]
        for root in [Self.bundledDir, Self.userDir].compactMap({ $0 }) { // user folder wins
            let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            for dir in dirs {
                guard let data = try? Data(contentsOf: dir.appendingPathComponent("plugin.json")),
                      let m = try? JSONDecoder().decode(Manifest.self, from: data) else { continue }
                byID[m.id] = TabItem(
                    id: m.id, name: m.name, symbol: m.symbol ?? "puzzlepiece.extension.fill", order: m.order ?? 100,
                    height: min(Self.maxHeight, CGFloat(m.height ?? Double(Self.defaultHeight))),
                    kind: .web(dir: dir, entry: m.entry ?? "index.html"),
                    icon: m.icon.map { dir.appendingPathComponent($0) }
                )
            }
        }
        let native = Self.nativeTabs.filter { byID[$0.id] == nil }
        tabs = (native + byID.values).sorted { ($0.order, $0.id) < ($1.order, $1.id) }
    }

    private func watch() {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let registry = Unmanaged<PluginRegistry>.fromOpaque(info).takeUnretainedValue()
            registry.reload()
            registry.revision += 1
        }
        guard let stream = FSEventStreamCreate(nil, callback, &context, [Self.userDir.path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.4,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes))
        else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }
}
