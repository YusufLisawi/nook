import AppKit
import Combine
import SwiftUI

enum NotchState { case closed, open }

/// What the closed notch shows on its sides, most important first.
enum Activity: Equatable {
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
    /// Whether the open notch's content is in the view tree. Keyboard entry attaches immediately; hover waits for the shape.
    /// Remove without animation when closing. SwiftUI keeps a removed view (and anything backed by an NSView: web tabs, tooltips, drag handlers) alive until
    /// the notch's size animation settles, which left the content hanging around as a ghost.
    @Published private(set) var showsContent = false
    var contentDidAttach: (() -> Void)?
    @Published var tab: String = "home" {
        willSet {
            if newValue != tab, launcherPresented {
                holdRect = liveRect.union(holdRect ?? .null)
                launcherDidClose?()
            }
            // A shorter tab shrinks the notch away from the dock the user just clicked; keep the old area "inside"
            // until the mouse re-enters the new shape or leaves the old one, so switching tabs never closes the notch.
            if isOpen, newValue != tab { holdRect = liveRect.union(holdRect ?? .null) }
        }
        didSet {
            guard tab != oldValue else { return }
            TabNavigationStore.shared.remember(tab)
            showingSettings = false
            web.visibilityChanged()
            web.emit("show", tab)
        }
    }
    @Published var geometry: NotchGeometry
    @Published var panelVisible = true
    @Published var isHovering = false
    @Published var isDropTargeted = false
    @Published var pinned = false
    @Published var heightOverrides: [String: CGFloat] = [:]
    @Published var slideEdge: Edge = .trailing
    /// The current tab's settings are showing in place of its content.
    @Published var showingSettings = false
    /// Native transient mode; its implementation and keyboard routing live in Services/Launcher.
    @Published var launcherPresented = false
    @Published var launcherHeight: CGFloat = 180
    var launcherKeyHandler: ((NSEvent) -> Bool)?
    var launcherEscape: (() -> Void)?
    var launcherDidClose: (() -> Void)?
    @Published private(set) var activity: Activity?

    let services = Services.shared
    lazy var web = WebPluginHost(vm: self)
    lazy var keyboard = NotchKeyboardState(vm: self)
    var keyboardRun: ((NotchKeyboardState.Entry, Bool) -> Void)?
    var onClose: (() -> Void)?
    /// The notch's shape before a tab switch; still counts as hovered (see `tab`).
    var holdRect: CGRect?
    private var pendingOpen: DispatchWorkItem?
    private var pendingReveal: DispatchWorkItem?
    private var bag = Set<AnyCancellable>()

    init(geometry: NotchGeometry) {
        self.geometry = geometry
        let s = services
        bindFeatureActivity()
        NotificationCenter.default.publisher(for: .nookFeaturesChanged).sink { [weak self] _ in
            guard let self else { return }
            self.bindFeatureActivity()
            if !Features.shared.enabled("keyboard") { self.keyboard.isPresented = false }
            self.reconcileTabNavigation()
            self.objectWillChange.send()
        }.store(in: &bag)
        s.plugins.$tabs.sink { [weak self] _ in
            self?.objectWillChange.send()
            DispatchQueue.main.async { self?.reconcileTabNavigation() }
        }.store(in: &bag)
        s.plugins.$customOrder.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        s.plugins.$userHeights.sink { [weak self] _ in withAnimation(Self.spring) { self?.objectWillChange.send() } }.store(in: &bag)
        TabNavigationStore.shared.objectWillChange.sink { [weak self] in
            // Preserve the old hit area even when a deck is created/deleted while open.
            guard let self else { return }
            if self.isOpen { self.holdRect = self.liveRect.union(self.holdRect ?? .null) }
            DispatchQueue.main.async { self.reconcileTabNavigation() }
        }.store(in: &bag)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.reconcileTabNavigation() }.store(in: &bag)

    }

    private var featureBag = Set<AnyCancellable>()
    private func bindFeatureActivity() {
        featureBag.removeAll()
        let f = Features.shared
        if f.enabled("media") {
            services.media.objectWillChange.sink { [weak self] in
                DispatchQueue.main.async { self?.updateActivity() }
            }.store(in: &featureBag)
        }
        if f.enabled("timers") {
            services.timers.objectWillChange.sink { [weak self] in
                DispatchQueue.main.async { self?.updateActivity() }
            }.store(in: &featureBag)
            services.timers.onFinish = { [weak self] in self?.open(tab: "timers") }
        }
        services.$pluginActivity.sink { [weak self] _ in DispatchQueue.main.async { self?.updateActivity() } }.store(in: &featureBag)
        updateActivity()
    }
    private func updateActivity() {
        let f = Features.shared
        let next: Activity?
        if let plugin = services.pluginActivity, f.tabEnabled(plugin.pluginID) { next = .plugin(plugin) }
        else if f.enabled("timers"), services.timers.isRunning, Prefs.bool(Prefs.showTimer) { next = .timer }
        else if f.enabled("media"), services.media.track?.isPlaying == true, Prefs.bool(Prefs.showMusic) { next = .music }
        else { next = nil }
        if activity != next { withAnimation(Self.spring) { activity = next } }
        else if next != nil { objectWillChange.send() }
    }

    var isOpen: Bool { state == .open }

    var enabledTabs: [TabItem] {
        let off = Prefs.disabledTabSet
        return services.plugins.orderedTabs.filter { !off.contains($0.id) && Features.shared.tabEnabled($0.id) }
    }

    var currentTab: TabItem? { enabledTabs.first { $0.id == tab } }

    func isEnabled(_ id: String) -> Bool { enabledTabs.contains { $0.id == id } }

    var contentHeight: CGFloat {
        // A plugin's live setHeight (e.g. teleprompter while playing) > the user's height > the manifest default.
        let base = currentTab.map { services.plugins.height(for: $0) } ?? PluginRegistry.defaultHeight
        return min(PluginRegistry.maxHeight, heightOverrides[tab] ?? base)
    }

    var contentSize: CGSize {
        let notch = geometry.notch.size
        switch state {
        case .open:
            if launcherPresented { return CGSize(width: 720, height: notch.height + launcherHeight) }
            return CGSize(width: max(Self.openWidth, notch.width + 300), height: notch.height + 8 + contentHeight + 8 + Self.dockHeight + 10 + (currentGroup == nil ? 0 : 34))
        case .closed:
            if let activity { return CGSize(width: notch.width + 2 * sideWidth(for: activity), height: notch.height) }
            guard isHovering else { return notch }
            // Click mode: a clearer "press me" grow, since hovering alone won't open it.
            return Prefs.bool(Prefs.openOnHover)
                ? CGSize(width: notch.width + 14, height: notch.height + 3)
                : CGSize(width: notch.width + 30, height: notch.height + 7)
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
        if !pinned && !keyboard.engaged { close() }
    }

    func open(tab: String? = nil) {
        if !isOpen {
            PluginHostAPI.shared.captureBeforeOpen(self)
        }
        if let tab { self.tab = tab }
        if !isEnabled(self.tab) { self.tab = enabledTabs.first?.id ?? "home" }
        guard !isOpen else {
            if keyboard.engaged {
                pendingReveal?.cancel()
                showsContent = true
            }
            return
        }
        if Prefs.bool(Prefs.haptics) {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
        pendingReveal?.cancel()
        withAnimation(Self.spring) {
            state = .open
            if keyboard.engaged { showsContent = true }
        }
        // Keep the contributor's delayed attachment for hover (NSViews can ignore fades during a resize).
        // Keyboard opens bypass it so initial native focus and launcher search are ready for the first key.
        let reveal = DispatchWorkItem { [weak self] in
            guard let self, self.isOpen else { return }
            withAnimation(.easeOut(duration: 0.18)) { self.showsContent = true }
        }
        pendingReveal = reveal
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: reveal)
        web.visibilityChanged()
        if !launcherPresented { web.emit("open", self.tab) }
    }

    /// Switch tab with a slide that matches the tab's position.
    func select(_ id: String) {
        guard id != tab, let (from, to) = navigationIndices(to: id) else { tab = id; return }
        slideEdge = to > from ? .trailing : .leading
        withAnimation(.snappy(duration: 0.28)) { tab = id }
    }

    /// Trackpad swipe: +1 next tab, -1 previous (wraps).
    func step(_ delta: Int) {
        let items = dockItems
        guard let id = DockLayout.step(from: currentDockID, by: delta, ids: items.map(\.id)),
              let item = items.first(where: { $0.id == id }) else { return }
        slideEdge = delta > 0 ? .trailing : .leading
        withAnimation(.snappy(duration: 0.28)) { selectDockItem(item) }
        if Prefs.bool(Prefs.haptics) { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
    }

    /// Hotkey: open on this tab, or close if it's already showing.
    func toggle(tab id: String) {
        if isOpen && tab == id { close() } else { open(tab: id) }
    }

    func close() {
        guard isOpen else { return }
        launcherDidClose?()
        holdRect = nil
        pinned = false
        showingSettings = false
        pendingReveal?.cancel()
        withAnimation(Self.spring) { state = .closed }
        // A separate update pass: when it shared one with the animated resize, SwiftUI could leave the shape at its open size.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isOpen else { return } // an immediate reopen owns the new content
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) {
                self.showsContent = false
            }
        }
        web.emit("close", tab)
        web.visibilityChanged()
        onClose?()
    }
}
