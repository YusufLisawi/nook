import AppKit
import ApplicationServices
import Darwin

/// Read-only private APIs, resolved at runtime. Missing symbols disable desktop moves, not Nook.
/// No WindowServer mutations, SIP exceptions, injected helpers or local-symbol-table patching.
final class WindowSpaces {
    private typealias Connection = @convention(c) () -> Int32
    private typealias Displays = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias Membership = @convention(c) (Int32, UInt32, CFArray) -> Unmanaged<CFArray>?
    private typealias WindowID = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    private var releaseDrag: (() -> Void)?
    func cancel() { releaseDrag?(); releaseDrag = nil }

    private let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private let process = dlopen(nil, RTLD_LAZY)

    deinit {
        if let skyLight { dlclose(skyLight) }
        if let process { dlclose(process) }
    }

    private func symbol<T>(_ names: [String], in handle: UnsafeMutableRawPointer?, as type: T.Type) -> T? {
        guard let handle else { return nil }
        for name in names {
            if let address = dlsym(handle, name) { return unsafeBitCast(address, to: type) }
        }
        return nil
    }

    private var connection: Int32? {
        symbol(["SLSMainConnectionID", "CGSMainConnectionID", "_CGSDefaultConnection"], in: skyLight, as: Connection.self)?()
    }

    func id(of window: ManagedWindow) -> CGWindowID? {
        guard let getID = symbol(["_AXUIElementGetWindow"], in: process, as: WindowID.self) else { return nil }
        var id = CGWindowID(0)
        return getID(window.element, &id) == .success && id != 0 ? id : nil
    }

    func memberships(_ id: CGWindowID) -> [UInt64] {
        guard let connection,
              let copy = symbol(["SLSCopySpacesForWindows", "CGSCopySpacesForWindows"], in: skyLight, as: Membership.self),
              let array = copy(connection, 0x7, [NSNumber(value: id)] as CFArray)?.takeRetainedValue() as? [NSNumber] else { return [] }
        return array.map(\.uint64Value)
    }

    func plan(windowID: CGWindowID, displayID: CGDirectDisplayID, step: Int) throws -> WindowDesktopPlan {
        guard let connection,
              let copy = symbol(["SLSCopyManagedDisplaySpaces", "CGSCopyManagedDisplaySpaces"], in: skyLight, as: Displays.self),
              let displays = copy(connection)?.takeRetainedValue() as? [[String: Any]] else {
            throw WindowManagementError("Desktop information is unavailable on this macOS version. Use Mission Control.")
        }
        let uuid = CGDisplayCreateUUIDFromDisplayID(displayID).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String }
        guard let display = displays.first(where: { ($0["Display Identifier"] as? String) == uuid })
                ?? displays.first(where: { ($0["Display Identifier"] as? String) == "Main" })
                ?? (displays.count == 1 ? displays.first : nil),
              let current = display["Current Space"] as? [String: Any],
              let spaces = display["Spaces"] as? [[String: Any]],
              let currentID = (current["ManagedSpaceID"] as? NSNumber)?.uint64Value else {
            throw WindowManagementError("Couldn't identify the window's desktop. Use Mission Control.")
        }
        return try WindowDesktopPlan.make(currentID: currentID, spaces: spaces, memberships: memberships(windowID), step: step)
    }

    /// Simulates the same drag + desktop switch a user can perform with SIP enabled.
    /// The caller serializes operations and closes the notch before entering here.
    @MainActor
    func move(_ window: ManagedWindow, screen: NSScreen, area: CGRect, step: Int) async throws {
        guard let id = id(of: window), let display = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            throw WindowManagementError("Couldn't identify this window for a desktop move. Use Mission Control.")
        }
        let plan = try plan(windowID: id, displayID: display.uint32Value, step: step)
        // Respect customized macOS desktop shortcuts, including disabled shortcuts.
        let shortcut = try desktopShortcut(step: step)
        for _ in 0..<30 {
            if CGEventSource.flagsState(.combinedSessionState).intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard CGEventSource.flagsState(.combinedSessionState).intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty,
              !CGEventSource.buttonState(.combinedSessionState, button: .left) else {
            throw WindowManagementError("Release the shortcut keys and mouse button, then try again.")
        }
        window.raise()
        try await Task.sleep(nanoseconds: 180_000_000)
        let appElement = AXUIElementCreateApplication(window.application.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.3)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == window.application.processIdentifier,
              let focused = WindowAX.element(appElement, kAXFocusedWindowAttribute),
              CFEqual(focused, window.element) else {
            throw WindowManagementError("Couldn't focus the captured window. Focus it and reopen the notch.")
        }
        let currentPlan = try self.plan(windowID: id, displayID: display.uint32Value, step: step)
        guard currentPlan.source == plan.source, currentPlan.destination == plan.destination else {
            throw WindowManagementError("The desktop changed while preparing the move. Try again.")
        }
        let original = try window.frame()
        guard WindowAX.isSettable(window.element, kAXPositionAttribute) else {
            throw WindowManagementError("This window does not allow moving. Focus a normal app window and try again.")
        }
        let point = try window.dragPoint(in: area)
        guard let source = CGEventSource(stateID: .privateState), let oldPointer = CGEvent(source: nil)?.location else {
            throw WindowManagementError("Couldn't prepare the desktop move. Try again.")
        }
        let nudge: CGFloat = point.x + 6 < area.maxX - 4 ? 6 : -6
        let heldPoint = CGPoint(x: point.x + nudge, y: point.y)
        var mouseHeld = false
        releaseDrag = { [weak self] in
            if mouseHeld { self?.postMouse(.leftMouseUp, at: CGEvent(source: nil)?.location ?? heldPoint, source: source); mouseHeld = false }
        }
        defer {
            releaseDrag = nil
            let pointer = CGEvent(source: nil)?.location ?? heldPoint
            if mouseHeld { postMouse(.leftMouseUp, at: pointer, source: source) }
            // Don't pull the pointer back if the user moved it during the transition.
            if hypot(pointer.x - heldPoint.x, pointer.y - heldPoint.y) < 24 {
                postMouse(.mouseMoved, at: oldPointer, source: source)
            }
            // Remove our drag nudge, unless macOS/the user moved the window further.
            if let frame = try? window.frame(), abs(frame.minX - original.minX) < 8, abs(frame.minY - original.minY) < 8 {
                _ = WindowAX.setPosition(window.element, original.origin)
            }
        }
        postMouse(.mouseMoved, at: point, source: source)
        postMouse(.leftMouseDown, at: point, source: source)
        mouseHeld = true
        try await Task.sleep(nanoseconds: 80_000_000)
        postMouse(.leftMouseDragged, at: heldPoint, source: source)
        var draggingWindow = false
        for _ in 0..<6 {
            try await Task.sleep(nanoseconds: 50_000_000)
            let frame = try window.frame()
            if abs(frame.minX - original.minX - nudge) < 2, abs(frame.minY - original.minY) < 2 {
                draggingWindow = true
                break
            }
        }
        guard draggingWindow,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == window.application.processIdentifier else {
            throw WindowManagementError("The title-bar drag did not start. Move this window with Mission Control.")
        }
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: shortcut.key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: shortcut.key, keyDown: false) else {
            throw WindowManagementError("Couldn't send the desktop shortcut. Try Mission Control.")
        }
        down.setIntegerValueField(.eventSourceUserData, value: 0x4E4F4F4B)
        up.setIntegerValueField(.eventSourceUserData, value: 0x4E4F4F4B)
        down.flags = shortcut.flags
        up.flags = shortcut.flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        // Keep the mouse held through the Mission Control animation (Reduce Motion can change timing).
        for _ in 0..<20 {
            try await Task.sleep(nanoseconds: 60_000_000)
            let pointer = CGEvent(source: nil)?.location ?? heldPoint
            guard hypot(pointer.x - heldPoint.x, pointer.y - heldPoint.y) < 24 else {
                throw WindowManagementError("Desktop move interrupted by the pointer. Check the window in Mission Control.")
            }
        }
        postMouse(.leftMouseUp, at: heldPoint, source: source)
        mouseHeld = false
        for _ in 0..<20 {
            let membership = memberships(id)
            if membership.contains(plan.destination), !membership.contains(plan.source) { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw WindowManagementError("macOS didn't confirm the desktop move. Check Mission Control shortcuts and the window's title bar.")
    }

    private func postMouse(_ type: CGEventType, at point: CGPoint, source: CGEventSource) {
        let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
        event?.flags = []
        event?.post(tap: .cghidEventTap)
    }

    private func desktopShortcut(step: Int) throws -> (key: CGKeyCode, flags: CGEventFlags) {
        let id = step < 0 ? "79" : "81"
        let defaults = UserDefaults(suiteName: "com.apple.symbolichotkeys")
        let entries = defaults?.dictionary(forKey: "AppleSymbolicHotKeys")
        guard let entry = entries?[id] as? [String: Any] else {
            return (step < 0 ? 123 : 124, .maskControl)
        }
        guard entry["enabled"] as? Bool == true,
              let value = entry["value"] as? [String: Any], value["type"] as? String == "standard",
              let params = value["parameters"] as? [NSNumber], params.count >= 3,
              (0...127).contains(params[1].intValue) else {
            throw WindowManagementError("Enable “Move left/right a space” in System Settings → Keyboard → Keyboard Shortcuts → Mission Control.")
        }
        return (CGKeyCode(params[1].uint16Value), CGEventFlags(rawValue: params[2].uint64Value).intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]))
    }
}
