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

    /// Best effort, like the original paste: bring the app back and refocus the field. Only refuse when the app is gone,
    /// or when the text an AI command was going to replace is readable and the user changed it meanwhile.
    /// AX element equality / "frontmost yet" checks are not used: Electron, Arc and BB fields never compare equal.
    /// `insertion` (dictation): put the caret where it was — after any selection, never replacing it.
    func restoreTarget(insertion: Bool = false) -> Bool {
        guard let application, !application.isTerminated else { return false }
        application.activate()
        if let element {
            AXUIElementSetMessagingTimeout(element, 0.2)
            _ = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            if insertion {
                if var point = SelectionInsertion.insertionPoint(originalRange), let value = AXValueCreate(.cfRange, &point) {
                    _ = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value)
                }
                return true
            }
            if var range, selection != nil, let value = AXValueCreate(.cfRange, &range) {
                _ = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value)
            }
            if let selection {
                var current: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &current) == .success,
                   let current = current as? String, !current.isEmpty, current != selection { return false }
            }
        }
        return true
    }
}
