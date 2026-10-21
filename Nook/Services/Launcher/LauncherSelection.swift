import AppKit
import ApplicationServices

/// Snapshot the external text target before making the panel key. No synthesized keystrokes on open.
/// Opaque AX text providers use SelectionGrabber's existing fallback only after restoring this app.
struct AICommandContext {
    let application: NSRunningApplication?
    let clipboard: String
    let selection: String?
    private let element: AXUIElement?
    private let range: AXValue?

    static func capture() -> Self {
        let app = NSWorkspace.shared.frontmostApplication
        let clipboard = NSPasteboard.general.string(forType: .string) ?? ""
        if app?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            return Self(application: nil, clipboard: clipboard, selection: nil, element: nil, range: nil)
        }
        guard AXIsProcessTrusted(), let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return Self(application: app, clipboard: clipboard, selection: nil, element: nil, range: nil)
        }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        // Bound synchronous AX work so an unresponsive external app cannot hold up the launcher frame.
        let deadline = CFAbsoluteTimeGetCurrent() + 0.018
        AXUIElementSetMessagingTimeout(axApp, 0.004)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return Self(application: app, clipboard: clipboard, selection: nil, element: nil, range: nil)
        }
        let element = value as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.004)
        func attribute(_ name: String) -> CFTypeRef? {
            guard CFAbsoluteTimeGetCurrent() < deadline else { return nil }
            var result: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(element, name as CFString, &result)
            return result
        }
        let selected = attribute(kAXSelectedTextAttribute) as? String
        var range: AXValue?
        if let raw = attribute(kAXSelectedTextRangeAttribute), CFGetTypeID(raw) == AXValueGetTypeID() { range = (raw as! AXValue) }
        if let selected, !selected.isEmpty {
            return Self(application: app, clipboard: clipboard, selection: selected, element: element, range: range)
        }
        let role = attribute(kAXRoleAttribute) as? String ?? ""
        if ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role),
           let text = attribute(kAXValueAttribute) as? String, !text.isEmpty {
            var all = CFRange(location: 0, length: (text as NSString).length)
            return Self(application: app, clipboard: clipboard, selection: text, element: element, range: AXValueCreate(.cfRange, &all))
        }
        return Self(application: app, clipboard: clipboard, selection: nil, element: element, range: range)
    }

    /// Return false rather than pasting into an unrelated application if the original app has gone away.
    func restoreTarget() -> Bool {
        guard let application, !application.isTerminated else { return false }
        application.activate()
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier else { return false }
        if let element {
            AXUIElementSetMessagingTimeout(element, 0.2)
            _ = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            let axApp = AXUIElementCreateApplication(application.processIdentifier)
            AXUIElementSetMessagingTimeout(axApp, 0.2)
            var focused: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
                  let focused, CFEqual(focused, element) else { return false }
            if let range, selection != nil,
               AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, range) != .success { return false }
            // Don't overwrite text the user changed while the model was working.
            if let selection {
                var current: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &current) == .success,
                      current as? String == selection else { return false }
            }
        }
        return true
    }
}
