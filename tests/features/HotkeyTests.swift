import AppKit

// The real monitor uses inert shortcut models; start() is never called, so no AX prompt/tap is installed.
struct DictationShortcut { var keyCode: Int?; var flags: CGEventFlags }
enum Modifiers { static let all: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand, .maskShift, .maskSecondaryFn] }
@main struct HotkeyTests {
    static func main() {
        let monitor = HotkeyMonitor()
        precondition(monitor.hold == nil && monitor.toggle == nil, "disabled Dictation must not reserve default gestures")
        let event = CGEvent(keyboardEventSource: nil, virtualKey: 49, keyDown: true)!
        event.flags = .maskAlternate
        precondition(monitor.handle(.keyDown, event) != nil, "disabled Dictation cannot swallow Option-Space")
        let modifiers = CGEvent(source: nil)!
        modifiers.flags = [.maskControl, .maskAlternate]
        var recorded = false
        monitor.onHoldStart = { recorded = true }
        _ = monitor.handle(.flagsChanged, modifiers)
        precondition(!recorded, "disabled Dictation cannot begin recording")
        monitor.stop(); monitor.stop()
        print("Features: real disabled hotkey monitor reserves no gestures, passes events through and stops idempotently; no events posted")
    }
}
