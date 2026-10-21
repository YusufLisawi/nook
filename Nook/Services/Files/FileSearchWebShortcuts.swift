import AppKit
import WebKit

/// Preserve the bundled web fallback's edit-menu routing for users who override
/// the native tab with a files plugin. Other web views keep ordinary text editing.
enum FileSearchWebShortcuts {
    private static var monitor: Any?
    static func register() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
            guard flags == .command || flags == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "c" else { return event }
            var view = NSApp.keyWindow?.firstResponder as? NSView
            while let current = view {
                if let web = current as? WKWebView, web.url?.deletingLastPathComponent().lastPathComponent == "files" {
                    web.evaluateJavaScript("window.nook && nook._emit('filesShortcut', '\(flags.contains(.shift) ? "copyFile" : "copyPath")')")
                    return nil
                }
                view = current.superview
            }
            return event
        }
    }
}
