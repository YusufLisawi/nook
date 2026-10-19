import AppKit
import SwiftUI

/// Owns the panel and polls the mouse at 30 Hz to drive hover, click-through and drag-to-shelf.
final class NotchController {
    static let panelSize = CGSize(width: 880, height: 480)

    let viewModel: NotchViewModel
    private var panel: NotchPanel?
    private var timer: Timer?
    private var lastHover = false
    private var dragChangeCount = NSPasteboard(name: .drag).changeCount
    private var ticks = 0
    private var hiddenForFullscreen = false

    init() {
        let screen = NotchGeometry.preferredScreen(named: UserDefaults.standard.string(forKey: Prefs.preferredScreen)) ?? NSScreen.screens[0]
        viewModel = NotchViewModel(geometry: .forScreen(screen))
    }

    func start() {
        rebuild()
        viewModel.startServices()
        viewModel.onClose = { [weak self] in self?.dropKeyFocus() }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.rebuild()
        }
        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            guard let self, self.viewModel.isOpen, !self.viewModel.liveRect.contains(NSEvent.mouseLocation) else { return }
            self.viewModel.close()
        }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func rebuild() {
        guard let screen = NotchGeometry.preferredScreen(named: UserDefaults.standard.string(forKey: Prefs.preferredScreen)) else { return }
        let geometry = NotchGeometry.forScreen(screen)
        viewModel.geometry = geometry
        let size = Self.panelSize
        let frame = CGRect(x: geometry.notch.midX - size.width / 2, y: screen.frame.maxY - size.height, width: size.width, height: size.height)
        if let panel {
            panel.setFrame(frame, display: true)
            return
        }
        let panel = NotchPanel(rect: frame)
        panel.onEscape = { [weak self] in self?.viewModel.close() }
        let host = NSHostingView(rootView: NotchRootView(vm: viewModel))
        host.frame = CGRect(origin: .zero, size: size)
        panel.contentView = host
        panel.orderFrontRegardless()
        self.panel = panel
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
        let inside = viewModel.liveRect.insetBy(dx: -2, dy: -6).contains(mouse)
        panel.ignoresMouseEvents = !inside

        if inside, draggingIn, !viewModel.isOpen, Prefs.bool(Prefs.shelfAutoOpen), viewModel.isEnabled(.shelf) {
            viewModel.open(tab: .shelf)
        }

        // Keep "hovering" while a drag that started inside is still held (e.g. dragging a file out of the shelf).
        let hover = inside || (pressed && lastHover)
        if hover != lastHover {
            lastHover = hover
            hover ? viewModel.hoverBegan() : viewModel.hoverEnded()
        }
    }

    private func updateFullscreenVisibility() {
        guard let panel else { return }
        let hide = Prefs.bool(Prefs.hideInFullscreen) && Self.frontAppIsFullscreen(on: viewModel.geometry.screen)
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
