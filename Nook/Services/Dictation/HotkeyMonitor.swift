import AppKit

/// FreeFlow's default shortcuts: hold ⌃⌥ to talk, ⌥Space to toggle. Needs Accessibility (an active event tap swallows ⌥Space).
final class HotkeyMonitor {
    var onHoldStart: () -> Void = {}
    var onHoldEnd: () -> Void = {}
    var onHoldCancel: () -> Void = {}
    var onToggle: () -> Void = {}
    /// Return true to swallow the key (used for per-tab shortcuts).
    var onShortcut: (Int64, CGEventFlags) -> Bool = { _, _ in false }

    private var tap: CFMachPort?
    private var holding = false
    private var retryTimer: Timer?
    private static let modifiers: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand, .maskShift]
    private static let spaceKey: Int64 = 49

    var isTrusted: Bool { AXIsProcessTrusted() }

    func start() {
        guard tap == nil else { return }
        if !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
            // Wait for the user to tick Nook in System Settings → Accessibility.
            retryTimer?.invalidate()
            retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
                guard AXIsProcessTrusted() else { return }
                timer.invalidate()
                self?.installTap()
            }
            return
        }
        installTap()
    }

    private func installTap() {
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            return Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: CGEventMask(mask), callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let mods = event.flags.intersection(Self.modifiers)
        switch type {
        case .flagsChanged:
            let wantHold = mods == [.maskControl, .maskAlternate]
            if wantHold, !holding {
                holding = true
                onHoldStart()
            } else if !wantHold, holding {
                holding = false
                onHoldEnd()
            }
        case .keyDown:
            let key = event.getIntegerValueField(.keyboardEventKeycode)
            if key == Self.spaceKey, mods == [.maskAlternate] {
                if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { onToggle() }
                return nil
            }
            if !mods.intersection([.maskControl, .maskAlternate, .maskCommand]).isEmpty,
               event.getIntegerValueField(.keyboardEventAutorepeat) == 0, onShortcut(key, mods) {
                if holding { holding = false; onHoldCancel() }
                return nil
            }
            if holding { // ⌃⌥ + another key is a normal shortcut, not dictation
                holding = false
                onHoldCancel()
            }
        case .keyUp:
            if event.getIntegerValueField(.keyboardEventKeycode) == Self.spaceKey, mods == [.maskAlternate] { return nil }
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }
}
