import AppKit
import Combine
import SwiftUI

enum NotchState { case closed, open }

enum NotchTab: String, CaseIterable, Identifiable {
    case home, shelf, scratch, timers, calendar

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .shelf: "Shelf"
        case .scratch: "Scratch"
        case .timers: "Timers"
        case .calendar: "Calendar"
        }
    }

    var icon: String {
        switch self {
        case .home: "house.fill"
        case .shelf: "tray.full.fill"
        case .scratch: "square.and.pencil"
        case .timers: "timer"
        case .calendar: "calendar"
        }
    }
}

/// What the closed notch shows on its sides.
enum Activity: Equatable { case music, timer }

final class NotchViewModel: ObservableObject {
    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.78, blendDuration: 0.1)
    static let openWidth: CGFloat = 680
    static let openExtraHeight: CGFloat = 210

    @Published var state: NotchState = .closed
    @Published var tab: NotchTab = .home
    @Published var geometry: NotchGeometry
    @Published var isHovering = false
    @Published var isDropTargeted = false
    @Published private(set) var activity: Activity?

    let media = MediaController()
    let timers = TimerService()
    let shelf = FileShelf()
    let calendar = CalendarService()

    var onClose: (() -> Void)?
    private var pendingOpen: DispatchWorkItem?
    private var bag = Set<AnyCancellable>()

    init(geometry: NotchGeometry) {
        self.geometry = geometry
        Publishers.CombineLatest(media.$track, timers.$isRunning)
            .map { track, timerRunning -> Activity? in
                if timerRunning, Prefs.bool(Prefs.showTimer) { return .timer }
                if track?.isPlaying == true, Prefs.bool(Prefs.showMusic) { return .music }
                return nil
            }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] activity in withAnimation(Self.spring) { self?.activity = activity } }
            .store(in: &bag)
        timers.onFinish = { [weak self] in self?.open(tab: .timers) }
    }

    func startServices() {
        media.start()
        calendar.start()
    }

    var isOpen: Bool { state == .open }

    var enabledTabs: [NotchTab] {
        let off = Prefs.disabledTabSet
        return NotchTab.allCases.filter { !off.contains($0.rawValue) }
    }

    func isEnabled(_ tab: NotchTab) -> Bool { enabledTabs.contains(tab) }

    var contentSize: CGSize {
        let notch = geometry.notch.size
        switch state {
        case .open:
            return CGSize(width: max(Self.openWidth, notch.width + 300), height: notch.height + Self.openExtraHeight)
        case .closed:
            if activity != nil { return CGSize(width: notch.width + 2 * (notch.height + 22), height: notch.height) }
            return isHovering ? CGSize(width: notch.width + 14, height: notch.height + 3) : notch
        }
    }

    /// The black shape's rect on screen; the mouse counts as "inside" only here.
    var liveRect: CGRect {
        let size = contentSize
        let screen = geometry.screen.frame
        return CGRect(x: geometry.notch.midX - size.width / 2, y: screen.maxY - size.height, width: size.width, height: size.height)
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
        close()
    }

    func open(tab: NotchTab? = nil) {
        if let tab { self.tab = tab }
        if !isEnabled(self.tab) { self.tab = enabledTabs.first ?? .home }
        guard !isOpen else { return }
        if Prefs.bool(Prefs.haptics) {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
        withAnimation(Self.spring) { state = .open }
    }

    func close() {
        guard isOpen else { return }
        withAnimation(Self.spring) { state = .closed }
        onClose?()
    }
}
