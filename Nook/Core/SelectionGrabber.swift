import AppKit
import ApplicationServices

enum SelectionGrabber {
    /// Accessibility first (no clipboard involved); falls back to a quick ⌘C with the clipboard restored after.
    static func selectedText() async -> String {
        if let text = axSelection(), !text.isEmpty { return text }
        let copied = await copySelection()
        if !copied.isEmpty { return copied }
        // Nothing selected but the cursor is in a text box → use (and select) everything in it.
        return await selectAllInFocusedInput()
    }

    private static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID() else { return nil }
        return (element as! AXUIElement)
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    /// Text fields, text areas, search fields, combo boxes — and editable web content (contenteditable, inputs).
    private static func isTextInput(_ element: AXUIElement) -> Bool {
        let role = attribute(element, kAXRoleAttribute) as? String ?? ""
        if ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role) { return true }
        return attribute(element, "AXEditableAncestor") != nil
    }

    private static func selectAllInFocusedInput() async -> String {
        guard let element = focusedElement(), isTextInput(element) else { return "" }
        if let value = attribute(element, kAXValueAttribute) as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var range = CFRange(location: 0, length: (value as NSString).length)
            if let axRange = AXValueCreate(.cfRange, &range),
               AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axRange) == .success {
                return value // selected via Accessibility, so "replace" swaps exactly this
            }
        }
        press(key: 0, flags: .maskCommand) // ⌘A — only ever inside a confirmed text input
        try? await Task.sleep(nanoseconds: 80_000_000)
        return await copySelection()
    }

    private static func axSelection() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID() else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element as! AXUIElement, kAXSelectedTextAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func copySelection() async -> String {
        let board = NSPasteboard.general
        let saved = snapshot(board)
        let before = board.changeCount
        LinkCatcher.ignoreClipboardUntil = Date().addingTimeInterval(1.5) // don't save our own ⌘C as a link
        press(key: 8, flags: .maskCommand) // ⌘C
        for _ in 0..<24 where board.changeCount == before { try? await Task.sleep(nanoseconds: 25_000_000) }
        let text = board.changeCount != before ? (board.string(forType: .string) ?? "") : ""
        restore(board, saved)
        return text
    }

    /// Put text in the frontmost app by pasting, then restore the user's clipboard.
    static func paste(_ text: String, after: Bool = false, keepOnClipboard: Bool = false) {
        let board = NSPasteboard.general
        let saved = snapshot(board)
        LinkCatcher.ignoreClipboardUntil = Date().addingTimeInterval(1.5)
        board.clearContents()
        let item = NSPasteboardItem()
        item.setString(after ? "\n\n" + text : text, forType: .string)
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType")) // clipboard managers skip it
        board.writeObjects([item])
        if after { press(key: 124, flags: []) } // → collapses the selection to its end
        press(key: 9, flags: .maskCommand) // ⌘V
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            if keepOnClipboard { // leave the answer (not the "\n\n"-prefixed paste) as a normal clipboard item
                LinkCatcher.ignoreClipboardUntil = Date().addingTimeInterval(1.5)
                board.clearContents()
                board.setString(text, forType: .string)
            } else {
                restore(board, saved)
            }
        }
    }

    private static func press(key: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private static func snapshot(_ board: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (board.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
        }
    }

    private static func restore(_ board: NSPasteboard, _ items: [[NSPasteboard.PasteboardType: Data]]) {
        LinkCatcher.ignoreClipboardUntil = Date().addingTimeInterval(1.5)
        board.clearContents()
        guard !items.isEmpty else { return }
        board.writeObjects(items.map { types in
            let item = NSPasteboardItem()
            for (type, data) in types { item.setData(data, forType: type) }
            return item
        })
    }
}
