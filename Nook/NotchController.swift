import AppKit
import SwiftUI

/// Owns the panel and polls the mouse at 30 Hz to drive hover, click-through and drag-to-shelf.
final class NotchController {
    static let panelSize = CGSize(width: 880, height: 520)

    let viewModel: NotchViewModel
    private var panel: NotchPanel?
    private var keyboard: NotchKeyboardController?
    private var timer: Timer?
    private var lastHover = false
    private var dragChangeCount = NSPasteboard(name: .drag).changeCount
    private var ticks = 0
    private var hiddenForFullscreen = false

    private var screen: NSScreen
    private var monitors: [Any] = []
    private var swipe = CGPoint.zero
    private var swipeAxis: Swipe = .undecided
    private var swipeFired = false
    private enum Swipe { case undecided, horizontal, vertical }

    init(screen: NSScreen) {
        self.screen = screen
        viewModel = NotchViewModel(geometry: .forScreen(screen))
    }

    func start() {
        rebuild()
        viewModel.onClose = { [weak self] in self?.keyboard?.didClose(); self?.dropKeyFocus() }
        let monitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            guard let self, self.viewModel.isOpen, !self.viewModel.pinned, !self.viewModel.liveRect.contains(NSEvent.mouseLocation),
                  self.viewModel.holdRect?.contains(NSEvent.mouseLocation) != true else { return }
            self.viewModel.close()
        }
        if let monitor { monitors.append(monitor) }
        if let scroll = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] event in
            self?.handleScroll(event) ?? event
        }) { monitors.append(scroll) }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        monitors.forEach(NSEvent.removeMonitor)
        viewModel.close()
        panel?.orderOut(nil)
        keyboard = nil
        panel = nil
    }

    func update(screen: NSScreen) {
        self.screen = screen
        rebuild()
    }

    func rebuild() {
        let geometry = NotchGeometry.forScreen(screen)
        viewModel.geometry = geometry
        let size = Self.panelSize
        let frame = CGRect(x: geometry.notch.midX - size.width / 2, y: screen.frame.maxY - size.height, width: size.width, height: size.height)
        if let panel {
            panel.setFrame(frame, display: true)
            return
        }
        let panel = NotchPanel(rect: frame)
        let keyboard = NotchKeyboardController(panel: panel, vm: viewModel)
        self.keyboard = keyboard
        viewModel.keyboardRun = { [weak keyboard] entry, alternate in keyboard?.run(entry, alternate: alternate) }
        panel.onEscape = { [weak keyboard] in keyboard?.escape() }
        let host = NSHostingView(rootView: NotchRootView(vm: viewModel))
        host.frame = CGRect(origin: .zero, size: size)
        panel.contentView = host
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func openWithKeyboard() {
        hiddenForFullscreen = false
        keyboard?.open()
    }

    func toggleWithKeyboard(tab: String) {
        if viewModel.isOpen && viewModel.tab == tab { viewModel.close() }
        else { viewModel.open(tab: tab); openWithKeyboard() }
    }

    private func tick() {
        guard let panel else { return }
        ticks += 1
        if ticks % 30 == 0 { updateFullscreenVisibility() }
        if hiddenForFullscreen { return }

        let mouse = NSEvent.mouseLocation
        let pressed = NSEvent.pressedMouseButtons & 1 != 0
        let dragBoard = NSPasteboard(name: .drag)
        if !pressed { dragChangeCount = dragBoard.changeCount }
        let draggingIn = pressed && dragBoard.changeCount != dragChangeCount

        // Grow the hit area upward so the very top pixel row counts as inside.
        let live = viewModel.liveRect.insetBy(dx: -2, dy: -6)
        if let hold = viewModel.holdRect, live.contains(mouse) || !hold.insetBy(dx: -2, dy: -6).contains(mouse) {
            viewModel.holdRect = nil
        }
        let inside = live.contains(mouse) || viewModel.holdRect?.insetBy(dx: -2, dy: -6).contains(mouse) == true
        panel.ignoresMouseEvents = !inside

        if inside, draggingIn, !viewModel.isOpen, Prefs.bool(Prefs.shelfAutoOpen), viewModel.isEnabled("shelf") {
            viewModel.open(tab: "shelf")
        }

        // Keep "hovering" while a drag that started inside is still held (e.g. dragging a file out of the shelf).
        let hover = inside || (pressed && lastHover)
        if hover != lastHover {
            lastHover = hover
            hover ? viewModel.hoverBegan() : viewModel.hoverEnded()
        }
    }

    /// Two-finger trackpad swipes over this notch. Mouse wheels (no gesture phase) pass straight through.
    private func handleScroll(_ event: NSEvent) -> NSEvent? {
        guard event.window === panel, event.hasPreciseScrollingDeltas, Prefs.bool(Prefs.swipes) else { return event }
        if event.momentumPhase != [] { return swipeAxis == .horizontal ? nil : event }
        guard event.phase != [] else { return event }
        if event.phase == .began {
            swipe = .zero
            swipeAxis = .undecided
            swipeFired = false
        }
        // Finger direction, whatever the "natural scrolling" setting: +x right, +y down.
        let sign: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
        swipe.x += event.scrollingDeltaX * sign
        swipe.y += event.scrollingDeltaY * sign
        if swipeAxis == .undecided, hypot(swipe.x, swipe.y) > 8 {
            swipeAxis = abs(swipe.x) > abs(swipe.y) ? .horizontal : .vertical
        }
        let vm = viewModel
        if !swipeFired {
            switch swipeAxis {
            case .horizontal where vm.isOpen && abs(swipe.x) > 50:
                swipeFired = true
                vm.step(swipe.x < 0 ? 1 : -1) // fingers left → next tab, like flipping pages
            case .vertical where !vm.isOpen && swipe.y > 25:
                swipeFired = true
                vm.open()
            case .vertical where vm.isOpen && swipe.y < -40 && NSEvent.mouseLocation.y > vm.liveRect.maxY - vm.geometry.notch.height - 6:
                swipeFired = true
                vm.close()
            default: break
            }
        }
        let consumed = swipeAxis == .horizontal || (swipeAxis == .vertical && (!vm.isOpen || swipeFired))
        if event.phase == .ended || event.phase == .cancelled { swipeAxis = consumed && swipeAxis == .horizontal ? .horizontal : .undecided }
        return consumed ? nil : event
    }

    private func updateFullscreenVisibility() {
        guard let panel else { return }
        let hide = !viewModel.keyboard.engaged && Prefs.bool(Prefs.hideInFullscreen) && Self.frontAppIsFullscreen(on: viewModel.geometry.screen)
        guard hide != hiddenForFullscreen else { return }
        hiddenForFullscreen = hide
        if hide {
            viewModel.close()
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    private static func frontAppIsFullscreen(on screen: NSScreen) -> Bool {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        return windows.contains { info in
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict)
            else { return false }
            return bounds.size == screen.frame.size
        }
    }

    /// A non-activating panel can stay key after closing and swallow keystrokes; hand focus back.
    private func dropKeyFocus() {
        guard let panel, panel.isKeyWindow else { return }
        panel.orderOut(nil)
        panel.orderFrontRegardless()
    }
}

