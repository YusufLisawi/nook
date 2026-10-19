import AppKit
import Combine
import SwiftUI

enum NotchState { case closed, open }

/// What the closed notch shows on its sides, most important first.
enum Activity: Equatable {
    case dictation(DictationService.Phase)
    case plugin(PluginActivity)
    case timer
    case music
}

/// State for one notch (one per screen). Services are shared.
final class NotchViewModel: ObservableObject {
    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.78, blendDuration: 0.1)
    static let openWidth: CGFloat = 680
    static let dockHeight: CGFloat = 30

    @Published var state: NotchState = .closed
    @Published var tab: String = "home" {
        didSet { if tab != oldValue { web.emit("show", tab) } }
    }
    @Published var geometry: NotchGeometry
    @Published var isHovering = false
    @Published var isDropTargeted = false
    @Published var pinned = false
    @Published var heightOverrides: [String: CGFloat] = [:]
    @Published var slideEdge: Edge = .trailing
    @Published private(set) var activity: Activity?

    let services = Services.shared
    lazy var web = WebPluginHost(vm: self)
    var onClose: (() -> Void)?
    private var pendingOpen: DispatchWorkItem?
    private var bag = Set<AnyCancellable>()

    init(geometry: NotchGeometry) {
        self.geometry = geometry
        let s = services
        Publishers.CombineLatest4(s.media.$track, s.timers.$isRunning, s.dictation.$phase, s.$pluginActivity)
            .map { track, timerRunning, dictation, plugin -> Activity? in
                if dictation != .idle { return .dictation(dictation) }
                if let plugin { return .plugin(plugin) }
                if timerRunning, Prefs.bool(Prefs.showTimer) { return .timer }
                if track?.isPlaying == true, Prefs.bool(Prefs.showMusic) { return .music }
                return nil
            }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] activity in withAnimation(Self.spring) { self?.activity = activity } }
            .store(in: &bag)
        s.plugins.$tabs.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        s.plugins.$customOrder.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        s.timers.onFinish = { [weak self] in self?.open(tab: "timers") }
    }

    var isOpen: Bool { state == .open }

    var enabledTabs: [TabItem] {
        let off = Prefs.disabledTabSet
        return services.plugins.orderedTabs.filter { !off.contains($0.id) }
    }

    var currentTab: TabItem? { enabledTabs.first { $0.id == tab } }

    func isEnabled(_ id: String) -> Bool { enabledTabs.contains { $0.id == id } }

    var contentHeight: CGFloat {
        min(PluginRegistry.maxHeight, heightOverrides[tab] ?? currentTab?.height ?? PluginRegistry.defaultHeight)
    }

    var contentSize: CGSize {
        let notch = geometry.notch.size
        switch state {
        case .open:
            return CGSize(width: max(Self.openWidth, notch.width + 300), height: notch.height + 8 + contentHeight + 8 + Self.dockHeight + 10)
        case .closed:
            if let activity { return CGSize(width: notch.width + 2 * sideWidth(for: activity), height: notch.height) }
            return isHovering ? CGSize(width: notch.width + 14, height: notch.height + 3) : notch
        }
    }

    private func sideWidth(for activity: Activity) -> CGFloat {
        let base = geometry.notch.height + 22
        if case let .plugin(p) = activity { return max(base, CGFloat(p.text.count) * 7 + 20) }
        return base
    }

    /// The black shape's rect on screen; the mouse counts as "inside" only here.
    var liveRect: CGRect {
        let size = contentSize
        return CGRect(x: geometry.notch.midX - size.width / 2, y: geometry.screen.frame.maxY - size.height, width: size.width, height: size.height)
    }

    func hoverBegan() {
        withAnimation(Self.spring) { isHovering = true }
        guard Prefs.bool(Prefs.openOnHover), !isOpen else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isHovering else { return }
            self.open()
        }
        pendingOpen = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    func hoverEnded() {
        pendingOpen?.cancel()
        withAnimation(Self.spring) { isHovering = false }
        if !pinned { close() }
    }

    func open(tab: String? = nil) {
        if let tab { self.tab = tab }
        if !isEnabled(self.tab) { self.tab = enabledTabs.first?.id ?? "home" }
        guard !isOpen else { return }
        if Prefs.bool(Prefs.haptics) {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
        withAnimation(Self.spring) { state = .open }
        web.emit("open", self.tab)
    }

    /// Switch tab with a slide that matches the tab's position.
    func select(_ id: String) {
        let ids = enabledTabs.map(\.id)
        guard id != tab, let from = ids.firstIndex(of: tab), let to = ids.firstIndex(of: id) else { tab = id; return }
        slideEdge = to > from ? .trailing : .leading
        withAnimation(.snappy(duration: 0.28)) { tab = id }
    }

    /// Trackpad swipe: +1 next tab, -1 previous (wraps).
    func step(_ delta: Int) {
        let ids = enabledTabs.map(\.id)
        guard !ids.isEmpty, let i = ids.firstIndex(of: tab) else { return }
        slideEdge = delta > 0 ? .trailing : .leading
        withAnimation(.snappy(duration: 0.28)) { tab = ids[(i + delta + ids.count) % ids.count] }
        if Prefs.bool(Prefs.haptics) { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
    }

    /// Hotkey: open on this tab, or close if it's already showing.
    func toggle(tab id: String) {
        if isOpen && tab == id { close() } else { open(tab: id) }
    }

    func close() {
        guard isOpen else { return }
        pinned = false
        withAnimation(Self.spring) { state = .closed }
        web.emit("close", tab)
        onClose?()
    }
}
