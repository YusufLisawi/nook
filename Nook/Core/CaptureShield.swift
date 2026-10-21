import AppKit

/// "Hide Nook from screen sharing": marks every Nook window (notch panels, menu bar icon, Settings) as not
/// shareable, so screen recorders, screenshots and meeting screen-share skip them while you still see them.
enum CaptureShield {
    static var isOn: Bool { Prefs.bool(Prefs.hideFromCapture) }

    static func start() {
        applyAll()
        let center = NotificationCenter.default
        // New windows (Settings, popovers, menus) pick it up when shown; the toggle applies instantly.
        center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            (note.object as? NSWindow).map(apply)
        }
        center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main) { note in
            (note.object as? NSWindow).map(apply)
        }
        center.addObserver(forName: NSWindow.didUpdateNotification, object: nil, queue: .main) { note in
            (note.object as? NSWindow).map(apply)
        }
        center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            guard isOn != lastApplied else { return }
            applyAll()
        }
    }

    static func apply(_ window: NSWindow) {
        let type: NSWindow.SharingType = isOn ? .none : .readOnly
        if window.sharingType != type { window.sharingType = type }
    }

    private static var lastApplied: Bool?

    private static func applyAll() {
        lastApplied = isOn
        NSApp.windows.forEach(apply)
    }
}
