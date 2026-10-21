import AppKit
import ApplicationServices

struct ManagedWindow {
    let element: AXUIElement
    let application: NSRunningApplication

    static func focused() throws -> ManagedWindow {
        guard AXIsProcessTrusted() else {
            throw WindowManagementError("Allow Nook in System Settings → Privacy & Security → Accessibility.")
        }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier, app.bundleIdentifier != "com.yusuf.nook" else {
            throw WindowManagementError("Focus an app window, then open the notch again.")
        }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.3)
        guard let element = WindowAX.element(appElement, kAXFocusedWindowAttribute) else {
            throw WindowManagementError("This app has no focused window. Focus a normal window and try again.")
        }
        AXUIElementSetMessagingTimeout(element, 0.3)
        guard WindowAX.attribute(element, kAXRoleAttribute) as? String == kAXWindowRole else {
            throw WindowManagementError("Close the dialog or sheet before moving this window.")
        }
        return ManagedWindow(element: element, application: app)
    }

    static func captured(_ info: [String: Any]) throws -> ManagedWindow {
        guard AXIsProcessTrusted(), let pid = info["pid"] as? Int32,
              let number = info["windowNumber"] as? Int,
              let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
            throw WindowManagementError("Focus a window, then reopen the notch. Accessibility must be allowed.")
        }
        let ax = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(ax, 0.2)
        let windows = WindowAX.attribute(ax, kAXWindowsAttribute) as? [AXUIElement] ?? []
        guard let window = windows.first(where: { WindowSpaces().id(of: ManagedWindow(element: $0, application: app)).map(Int.init) == number }) else {
            throw WindowManagementError("The captured window is unavailable. Reopen the notch.")
        }
        AXUIElementSetMessagingTimeout(window, 0.2)
        let value = ManagedWindow(element: window, application: app)
        _ = try value.frame()
        return value
    }

    func frame() throws -> CGRect {
        guard !application.isTerminated,
              let position = WindowAX.point(element, kAXPositionAttribute),
              let size = WindowAX.size(element, kAXSizeAttribute),
              position.x.isFinite, position.y.isFinite, size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else {
            throw WindowManagementError("The window is no longer available. Focus it and reopen the notch.")
        }
        guard WindowAX.attribute(element, kAXMinimizedAttribute) as? Bool != true else {
            throw WindowManagementError("Unminimize this window before moving it.")
        }
        guard WindowAX.attribute(element, "AXFullScreen") as? Bool != true else {
            throw WindowManagementError("Leave full screen or Split View before moving this window.")
        }
        return CGRect(origin: position, size: size)
    }

    func setFrame(_ requested: CGRect, area: CGRect) throws {
        let before = try frame()
        let changesSize = abs(before.width - requested.width) > 1 || abs(before.height - requested.height) > 1
        guard WindowAX.isSettable(element, kAXPositionAttribute),
              !changesSize || WindowAX.isSettable(element, kAXSizeAttribute) else {
            throw WindowManagementError("This window does not allow that move or resize.")
        }
        // A small window must cross to the destination display before growing. Some apps constrain
        // the first size to their current display, so apply size → position → size → position.
        if changesSize { _ = WindowAX.setSize(element, requested.size) }
        let positioned = WindowAX.setPosition(element, requested.origin)
        if changesSize { _ = WindowAX.setSize(element, requested.size) }
        let actual = try frame()
        // Respect an app's minimum size: fit its actual size, retaining the requested edge alignment.
        var adjusted = requested
        adjusted.size = actual.size
        if abs(requested.maxX - area.maxX) < 1 { adjusted.origin.x = area.maxX - actual.width }
        if abs(requested.maxY - area.maxY) < 1 { adjusted.origin.y = area.maxY - actual.height }
        adjusted.origin.x = max(area.minX, min(adjusted.minX, area.maxX - actual.width))
        adjusted.origin.y = max(area.minY, min(adjusted.minY, area.maxY - actual.height))
        let repositioned = WindowAX.setPosition(element, adjusted.origin)
        guard positioned || repositioned else { throw WindowManagementError("The app refused to move this window.") }
        let result = try frame()
        guard abs(result.minX - adjusted.minX) <= 8, abs(result.minY - adjusted.minY) <= 8 else {
            throw WindowManagementError("The app constrained this window's position. Try a larger layout.")
        }
        if changesSize, abs(result.width - requested.width) > 8 || abs(result.height - requested.height) > 8 {
            throw WindowManagementError("The app constrained this window's size. Try a larger layout.")
        }
    }

    func raise() {
        application.activate()
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    }

    /// Only use an exposed title or empty title-bar area. Never click an arbitrary toolbar control.
    func dragPoint(in area: CGRect) throws -> CGPoint {
        let rect = try frame()
        var candidates: [CGPoint] = []
        if let title = WindowAX.element(element, kAXTitleUIElementAttribute),
           let origin = WindowAX.point(title, kAXPositionAttribute),
           let size = WindowAX.size(title, kAXSizeAttribute), size.width > 0, size.height > 0 {
            candidates.append(CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2))
        }
        candidates += [0.5, 0.7, 0.3].map { CGPoint(x: rect.minX + rect.width * $0, y: rect.minY + 8) }
        for point in candidates where area.insetBy(dx: 4, dy: 4).contains(point) && point.y < rect.minY + 48 {
            var hit: AXUIElement?
            guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success,
                  let hit else { continue }
            AXUIElementSetMessagingTimeout(hit, 0.3)
            let role = WindowAX.attribute(hit, kAXRoleAttribute) as? String ?? ""
            guard [kAXWindowRole, kAXStaticTextRole, "AXTitleBar"].contains(role) else { continue }
            if CFEqual(hit, element) { return point }
            if let owner = WindowAX.element(hit, kAXWindowAttribute), CFEqual(owner, element),
               let title = WindowAX.element(element, kAXTitleUIElementAttribute), CFEqual(hit, title) {
                return point
            }
        }
        throw WindowManagementError("This window has no accessible draggable title bar. Move it with Mission Control.")
    }
}

enum WindowAX {
    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    static func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func point(_ element: AXUIElement, _ name: String) -> CGPoint? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        var point = CGPoint.zero
        return AXValueGetType(axValue) == .cgPoint && AXValueGetValue(axValue, .cgPoint, &point) ? point : nil
    }

    static func size(_ element: AXUIElement, _ name: String) -> CGSize? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        var size = CGSize.zero
        return AXValueGetType(axValue) == .cgSize && AXValueGetValue(axValue, .cgSize, &size) ? size : nil
    }

    static func isSettable(_ element: AXUIElement, _ name: String) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success && settable.boolValue
    }

    static func setPosition(_ element: AXUIElement, _ point: CGPoint) -> Bool {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return false }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value) == .success
    }

    static func setSize(_ element: AXUIElement, _ size: CGSize) -> Bool {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value) == .success
    }
}
