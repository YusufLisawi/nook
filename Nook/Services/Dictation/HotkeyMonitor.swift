import AppKit

/// Global shortcuts via an active event tap (needs Accessibility; it can swallow keys).
/// Hold: record while held. Toggle: press to start, press again to stop and transcribe. Both are configurable.
final class HotkeyMonitor {
    var hold: DictationShortcut? = .defaultHold
    var toggle: DictationShortcut? = .defaultToggle
    var paused = false

    var onHoldStart: () -> Void = {}
    var onHoldEnd: () -> Void = {}
    var onHoldCancel: () -> Void = {}
    var onToggle: () -> Void = {}
    /// Return true to swallow the key (used for per-tab shortcuts).
    var onShortcut: (Int64, CGEventFlags) -> Bool = { _, _ in false }

    private var tap: CFMachPort?
    private var retryTimer: Timer?
    private var holding = false
    private var holdByKey = false
    private var toggleArmed = false
    private var swallowedKey: Int64?

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

    func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        // Remapped mouse keys belong to the target app, including their releases. Never mutate
        // dictation/shortcut state or swallow them, even if a physical shortcut is already held.
        if NookSyntheticInput.isMouseEvent(event) {
            return Unmanaged.passUnretained(event)
        }
        guard !paused else { return Unmanaged.passUnretained(event) }
        let mods = event.flags.intersection(Modifiers.all)
        let keyMods = mods.subtracting(.maskSecondaryFn) // arrows/F-keys carry fn; ignore it for key combos

        switch type {
        case .flagsChanged:
            if let hold, hold.keyCode == nil {
                let want = mods == hold.flags
                if want, !holding {
                    holding = true
                    onHoldStart()
                } else if !want, holding, !holdByKey {
                    holding = false
                    onHoldEnd()
                }
            }
            // Modifier-only toggle fires on release, if no other key was pressed in between.
            if let toggle, toggle.keyCode == nil {
                if mods == toggle.flags {
                    toggleArmed = true
                } else if mods.isEmpty, toggleArmed {
                    toggleArmed = false
                    onToggle()
                } else if !mods.isSubset(of: toggle.flags) {
                    toggleArmed = false
                }
            }

        case .keyDown:
            toggleArmed = false
            let key = event.getIntegerValueField(.keyboardEventKeycode)
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if isRepeat, swallowedKey == key { return nil }
            if let toggle, toggle.keyCode.map(Int64.init) == key, keyMods == toggle.flags {
                if !isRepeat { onToggle() }
                swallowedKey = key
                return nil
            }
            if let hold, hold.keyCode.map(Int64.init) == key, keyMods == hold.flags {
                if !isRepeat, !holding {
                    holding = true
                    holdByKey = true
                    onHoldStart()
                }
                swallowedKey = key
                return nil
            }
            if !keyMods.intersection([.maskControl, .maskAlternate, .maskCommand]).isEmpty, !isRepeat, onShortcut(key, keyMods) {
                swallowedKey = key
                if holding, !holdByKey { holding = false; onHoldCancel() }
                return nil
            }
            if holding, !holdByKey { // modifier hold + another key is a normal shortcut, not dictation
                holding = false
                onHoldCancel()
            }

        case .keyUp:
            let key = event.getIntegerValueField(.keyboardEventKeycode)
            if key == swallowedKey {
                swallowedKey = nil
                if holdByKey, holding {
                    holding = false
                    holdByKey = false
                    onHoldEnd()
                }
                return nil
            }

        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }
}
