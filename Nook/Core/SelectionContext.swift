import AppKit
import ApplicationServices

/// Snapshot the external text target before making the panel key. No synthesized keystrokes on open.
/// Opaque AX text providers use SelectionGrabber's existing fallback only after restoring this app.
struct AICommandContext {
    let application: NSRunningApplication?
    let clipboard: String
    let selection: String?
    private let element: AXUIElement?
    private let range: CFRange?
    private let originalRange: CFRange?

    static func capture() -> Self {
        let app = NSWorkspace.shared.frontmostApplication
        let clipboard = NSPasteboard.general.string(forType: .string) ?? ""
        if app?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            return Self(application: nil, clipboard: clipboard, selection: nil, element: nil, range: nil, originalRange: nil)
        }
        guard AXIsProcessTrusted(), let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return Self(application: app, clipboard: clipboard, selection: nil, element: nil, range: nil, originalRange: nil)
        }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        // Bound synchronous AX work so an unresponsive external app cannot hold up the launcher frame.
        let deadline = CFAbsoluteTimeGetCurrent() + 0.018
        AXUIElementSetMessagingTimeout(axApp, 0.004)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return Self(application: app, clipboard: clipboard, selection: nil, element: nil, range: nil, originalRange: nil)
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
        var range: CFRange?
        if let raw = attribute(kAXSelectedTextRangeAttribute), CFGetTypeID(raw) == AXValueGetTypeID() {
            var value = CFRange(location: 0, length: 0)
            if AXValueGetValue(unsafeBitCast(raw, to: AXValue.self), .cfRange, &value) { range = value }
        }
        var fullText: String?
        if selected?.isEmpty != false {
            let role = attribute(kAXRoleAttribute) as? String ?? ""
            if ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role) {
                fullText = attribute(kAXValueAttribute) as? String
            }
        }
        let plan = SelectionInsertion.capture(selected: selected, fullText: fullText, range: range)
        return Self(application: app, clipboard: clipboard, selection: plan.selection, element: element,
                    range: plan.commandRange, originalRange: plan.originalRange)
    }

    /// Return false rather than pasting into an unrelated application if the original app has gone away.
    func restoreTarget(insertion: Bool = false) -> Bool {
        guard let application, !application.isTerminated else { return false }
        application.activate()
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier else { return false }
        if insertion, element == nil { return false }
        if let element {
            AXUIElementSetMessagingTimeout(element, 0.2)
            let axApp = AXUIElementCreateApplication(application.processIdentifier)
            AXUIElementSetMessagingTimeout(axApp, 0.2)
            func isFocused() -> Bool {
                var focused: CFTypeRef?
                return AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focused) == .success &&
                    focused.map { CFEqual($0, element) } == true
            }
            // Avoid disturbing an already focused caret. AI Commands retain their existing refocus behavior.
            if !insertion || !isFocused() {
                _ = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            }
            guard isFocused() else { return false }
            if insertion {
                guard var point = SelectionInsertion.insertionPoint(originalRange) else { return false }
                func currentRange() -> CFRange? {
                    var actual: CFTypeRef?
                    var value = CFRange(location: 0, length: 0)
                    guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &actual) == .success,
                          let actual, CFGetTypeID(actual) == AXValueGetTypeID(),
                          AXValueGetValue(unsafeBitCast(actual, to: AXValue.self), .cfRange, &value) else { return nil }
                    return value
                }
                // Some editors expose a readable but non-settable range. If the caret is already
                // correct, leaving it in place is safe and avoids excluding those editors.
                if SelectionInsertion.matches(currentRange(), point: point) { return true }
                guard let value = AXValueCreate(.cfRange, &point),
                      AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success else { return false }
                return SelectionInsertion.matches(currentRange(), point: point)
            }
            if var range, selection != nil {
                guard let value = AXValueCreate(.cfRange, &range),
                      AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success else { return false }
            }
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
