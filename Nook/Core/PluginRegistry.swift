import AppKit

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
    var settings: [PluginSetting] = []

    var isWeb: Bool { if case .web = kind { true } else { false } }
    var dir: URL? { if case let .web(dir, _) = kind { dir } else { nil } }
}

/// Lists native tabs plus folder plugins (bundled + ~/Library/Application Support/Nook/Plugins), and hot-reloads on change.
final class PluginRegistry: ObservableObject {
    static let defaultHeight: CGFloat = 210
    static let maxHeight: CGFloat = 400

    static var userDir: URL { Services.supportDir.appendingPathComponent("Plugins", isDirectory: true) }
    static var bundledDir: URL? { Bundle.main.resourceURL?.appendingPathComponent("Plugins", isDirectory: true) }

    static let nativeTabs: [TabItem] = [
        TabItem(id: "media", name: "Now Playing", symbol: "music.note", order: 20, height: defaultHeight, kind: .native, icon: nil),
        TabItem(id: "shelf", name: "Shelf", symbol: "tray.full.fill", order: 30, height: defaultHeight, kind: .native, icon: nil),
        TabItem(id: "scratch", name: "Scratch", symbol: "square.and.pencil", order: 35, height: defaultHeight, kind: .native, icon: nil),
        TabItem(id: "files", name: "File Search", symbol: "doc.text.magnifyingglass", order: 46, height: 380, kind: .native, icon: nil),
        TabItem(id: "timers", name: "Timers", symbol: "timer", order: 80, height: defaultHeight, kind: .native, icon: nil),
    ]

    @Published private(set) var tabs: [TabItem] = nativeTabs
    /// User's drag-and-drop dock order (tab ids). Empty = manifest `order`.
    @Published private(set) var customOrder: [String] = UserDefaults.standard.stringArray(forKey: "tabOrder") ?? []
    /// User-chosen content height per tab (points). Overrides the manifest's `height`.
    @Published private(set) var userHeights: [String: CGFloat] =
        (UserDefaults.standard.dictionary(forKey: "tabHeights") as? [String: Double] ?? [:]).mapValues { CGFloat($0) }
    static let minHeight: CGFloat = 120

    /// What the tab opens at: the user's choice, else the plugin's own default.
    func height(for tab: TabItem) -> CGFloat { userHeights[tab.id] ?? tab.height }

    func setHeight(_ id: String, _ height: CGFloat?) {
        userHeights[id] = height.map { min(Self.maxHeight, max(Self.minHeight, $0)) }
        UserDefaults.standard.set(userHeights.mapValues { Double($0) }, forKey: "tabHeights")
    }

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
        var settings: [PluginSetting]?
    }

    func start() {
        try? FileManager.default.createDirectory(at: Self.userDir, withIntermediateDirectories: true)
        reload()
        watch()
    }

    func reload() {
        tabs = Self.discoverTabs()
    }

    /// Settings can refresh a large plugin directory without blocking window interaction.
    @MainActor func reloadForSettings() async {
        let version = revision
        let discovered = await Task.detached(priority: .utility) { Self.discoverTabs() }.value
        guard version == revision else { return } // a newer filesystem event already refreshed the registry
        tabs = discovered
        touch()
    }

    private static func discoverTabs() -> [TabItem] {
        var byID: [String: TabItem] = [:]
        for root in [Self.bundledDir, Self.userDir].compactMap({ $0 }) { // user folder wins
            let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            for dir in dirs {
                guard let data = try? Data(contentsOf: dir.appendingPathComponent("plugin.json")),
                      let m = try? JSONDecoder().decode(Manifest.self, from: data) else { continue }
                if m.id == "files", root == Self.bundledDir { continue } // Native by default; user web overrides still work.
                byID[m.id] = TabItem(
                    id: m.id, name: m.name, symbol: m.symbol ?? "puzzlepiece.extension.fill", order: m.order ?? 100,
                    height: min(Self.maxHeight, CGFloat(m.height ?? Double(Self.defaultHeight))),
                    kind: .web(dir: dir, entry: m.entry ?? "index.html"),
                    icon: m.icon.map { dir.appendingPathComponent($0) },
                    settings: m.settings ?? []
                )
            }
        }
        let native = Self.nativeTabs.filter { byID[$0.id] == nil }
        return (native + byID.values).sorted { ($0.order, $0.id) < ($1.order, $1.id) }
    }

    /// Tabs in dock order: the user's order first, then any new plugins by manifest order.
    var orderedTabs: [TabItem] {
        guard !customOrder.isEmpty else { return tabs }
        let known = customOrder.compactMap { id in tabs.first { $0.id == id } }
        return known + tabs.filter { !customOrder.contains($0.id) }
    }

    func move(_ id: String, to target: String) {
        var ids = orderedTabs.map(\.id)
        guard id != target, let from = ids.firstIndex(of: id), let to = ids.firstIndex(of: target) else { return }
        ids.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        setOrder(ids)
    }

    /// Settings list uses the same persisted order as dragging icons in the notch dock.
    func move(from source: IndexSet, to destination: Int) {
        var ids = orderedTabs.map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        setOrder(ids)
    }

    func resetOrder() { setOrder([]) }

    private func setOrder(_ ids: [String]) {
        customOrder = ids
        UserDefaults.standard.set(ids, forKey: "tabOrder")
    }

    // MARK: Code-level customisation

    func isBundled(_ tab: TabItem) -> Bool {
        guard let dir = tab.dir, let bundled = Self.bundledDir else { return false }
        return dir.standardizedFileURL.path.hasPrefix(bundled.standardizedFileURL.path)
    }

    /// A user plugin that replaces a bundled one with the same id.
    func overridesBundled(_ tab: TabItem) -> Bool {
        guard !isBundled(tab), let bundled = Self.bundledDir else { return false }
        return FileManager.default.fileExists(atPath: bundled.appendingPathComponent(tab.id).path)
    }

    /// Bundled → copy into the user folder (the copy then wins). Either way, open the folder.
    func customize(_ tab: TabItem) {
        guard let dir = tab.dir else { return }
        var target = dir
        if isBundled(tab) {
            target = Self.userDir.appendingPathComponent(tab.id, isDirectory: true)
            if !FileManager.default.fileExists(atPath: target.path) {
                try? FileManager.default.copyItem(at: dir, to: target)
            }
            reload()
            touch()
        }
        NSWorkspace.shared.activateFileViewerSelecting([target.appendingPathComponent("plugin.json")])
    }

    /// Drop the user's copy (to the Trash) so the bundled plugin is used again.
    func revert(_ tab: TabItem) {
        guard overridesBundled(tab), let dir = tab.dir else { return }
        try? FileManager.default.trashItem(at: dir, resultingItemURL: nil)
        reload()
        touch()
    }

    /// Force web plugins to reload (e.g. `nook reload`).
    func touch() { revision += 1 }

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
