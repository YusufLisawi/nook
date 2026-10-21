import AppKit

/// Transparent, borderless panel that floats over the menu bar on every space.
final class NotchPanel: NSPanel {
    var onEscape: (() -> Void)?

    init(rect: CGRect) {
        super.init(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        CaptureShield.apply(self)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEscape?() }

    /// The panel never activates Nook, so the menu bar can't deliver ⌘A/⌘C/⌘V/⌘X/⌘Z. Route them to the focused text field ourselves.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        guard mods == .command || mods == [.command, .shift] else { return super.performKeyEquivalent(with: event) }
        let shift = mods.contains(.shift)
        let action: Selector? = switch event.charactersIgnoringModifiers?.lowercased() {
        case "a" where !shift: #selector(NSResponder.selectAll(_:))
        case "c" where !shift: #selector(NSText.copy(_:))
        case "v" where !shift: #selector(NSText.paste(_:))
        case "x" where !shift: #selector(NSText.cut(_:))
        case "z": Selector(shift ? "redo:" : "undo:")
        default: nil
        }
        if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        return super.performKeyEquivalent(with: event)
    }
}
