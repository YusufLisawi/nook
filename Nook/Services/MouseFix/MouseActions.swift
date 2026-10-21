import AppKit

/// Things a mouse button can do. Most post the same keystroke you'd press yourself, so they follow your
/// System Settings → Keyboard → Shortcuts (Mission Control, Launchpad and the media keys don't need one).
enum MouseActions {
    static let all: [(id: String, label: String)] = [
        ("none", "Default"),
        ("missionControl", "Mission Control"),
        ("appExpose", "App Exposé"),
        ("launchpad", "Launchpad"),
        ("showDesktop", "Show Desktop"),
        ("spaceLeft", "Space to the left"),
        ("spaceRight", "Space to the right"),
        ("back", "Back"),
        ("forward", "Forward"),
        ("middleClick", "Middle click"),
        ("lookUp", "Look up"),
        ("screenshot", "Screenshot"),
        ("copy", "Copy"),
        ("paste", "Paste"),
        ("newTab", "New tab"),
        ("closeTab", "Close tab"),
        ("playPause", "Play / pause"),
        ("nextTrack", "Next track"),
        ("previousTrack", "Previous track"),
        ("volumeUp", "Volume up"),
        ("volumeDown", "Volume down"),
        ("mute", "Mute"),
    ]

    /// Safe from any thread.
    static func run(_ id: String) {
        switch id {
        case "missionControl": openApp(path: "/System/Applications/Mission Control.app")
        case "launchpad": openApp(bundleIDs: ["com.apple.launchpad.launcher", "com.apple.apps.launcher"])
        case "appExpose": key(125, .maskControl)
        case "showDesktop": key(103)
        case "spaceLeft": key(123, .maskControl)
        case "spaceRight": key(124, .maskControl)
        case "back": key(33, .maskCommand) // ⌘[
        case "forward": key(30, .maskCommand) // ⌘]
        case "lookUp": key(2, [.maskControl, .maskCommand]) // ⌃⌘D
        case "screenshot": key(21, [.maskShift, .maskCommand]) // ⇧⌘4
        case "copy": key(8, .maskCommand)
        case "paste": key(9, .maskCommand)
        case "newTab": key(17, .maskCommand)
        case "closeTab": key(13, .maskCommand)
        case "middleClick": click(button: 2)
        case "playPause": mediaKey(16)
        case "nextTrack": mediaKey(17)
        case "previousTrack": mediaKey(18)
        case "volumeUp": mediaKey(0)
        case "volumeDown": mediaKey(1)
        case "mute": mediaKey(7)
        default: break
        }
    }

    private static func key(_ code: CGKeyCode, _ flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { continue }
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: MouseFixService.marker)
            event.post(tap: .cghidEventTap)
        }
    }

    /// A press + release of one of the extra buttons (2 = middle, 3 = back…) at the pointer; tagged so our own tap lets it through.
    static func click(button: Int64) {
        let at = CGEvent(source: nil)?.location ?? .zero
        for type in [CGEventType.otherMouseDown, .otherMouseUp] {
            guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: at, mouseButton: .center) else { continue }
            event.setIntegerValueField(.mouseEventButtonNumber, value: button) // CGMouseButton only names left, right and center
            event.setIntegerValueField(.eventSourceUserData, value: MouseFixService.marker)
            event.post(tap: .cghidEventTap)
        }
    }

    /// Hardware keys (play, volume…) travel as system-defined events, not key codes.
    private static func mediaKey(_ key: Int) {
        for down in [true, false] {
            let state = down ? 0xA : 0xB
            NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                               timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
                               data1: (key << 16) | (state << 8), data2: -1)?.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    private static func openApp(path: String) {
        DispatchQueue.main.async { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
    }

    private static func openApp(bundleIDs: [String]) {
        DispatchQueue.main.async {
            let url = bundleIDs.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
            if let url { NSWorkspace.shared.open(url) }
        }
    }
}
