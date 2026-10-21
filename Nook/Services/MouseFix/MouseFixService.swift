import AppKit

/// Mouse tab engine: smooth wheel scrolling, scroll modifiers and button remapping for any mouse.
///
/// One active event tap (needs Accessibility) runs on its own thread, so scrolling stays smooth even while the
/// notch UI is busy. It only handles wheel clicks and the extra buttons (middle, back, forward…): left/right
/// clicks and pointer movement are never touched. The tap drains outstanding releases before stopping.
final class MouseFixService {
    /// Stamped on events we post so our own tap lets them through.
    static let marker = NookSyntheticInput.mouseMarker

    private let lock = NSLock()
    private var _config = MouseConfig.load()
    private var _learning = false
    private var _running = false
    private var _error: String?

    private var tapThread: TapThread?
    private var trustTimer: Timer?
    private var learnTimeout: DispatchWorkItem?

    var config: MouseConfig {
        get { lock.withLock { _config } }
        set { lock.withLock { _config = newValue }; newValue.save() }
    }

    fileprivate var learning: Bool { lock.withLock { _learning } }
    private var isRunning: Bool { lock.withLock { _running } }
    fileprivate func report(running: Bool, error: String? = nil) {
        lock.withLock { _running = running; _error = error }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            PluginEvents.emit("mouse", self.state(), to: "mouse")
        }
    }

    // MARK: Lifecycle

    func start() { reconfigure(prompt: false) }

    func shutdown() {
        trustTimer?.invalidate()
        tapThread?.stopAndWait()
        tapThread = nil
        CGAssociateMouseAndMouseCursorPosition(1) // never leave the pointer frozen
    }

    /// Keep a live tap until every swallowed physical button has released. Permission and tap
    /// failures are retried while wanted, including permission revocation after successful startup.
    private func reconfigure(prompt: Bool) {
        let wanted = config.enabled || learning
        if !wanted {
            tapThread?.setWanted(false)
            trustTimer?.invalidate()
            trustTimer = nil
            return
        }
        if trustTimer == nil {
            trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                self?.reconfigure(prompt: false)
            }
        }
        guard AXIsProcessTrusted() else {
            tapThread?.setWanted(false)
            report(running: false, error: "Allow Nook in Accessibility to use mouse controls.")
            if prompt {
                AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            }
            return
        }
        if let thread = tapThread, !thread.isFinished {
            thread.setWanted(true)
            return
        }
        let thread = TapThread(service: self)
        tapThread = thread
        thread.start()
    }

    // MARK: Bridge

    func handle(_ fn: String, args: [Any], reply: @escaping (Any?, String?) -> Void) {
        switch fn {
        case "state": break
        case "set":
            guard let next = config.merging(args.first as? [String: Any] ?? [:]) else { return reply(nil, "Invalid setting") }
            let turnedOn = next.enabled && !config.enabled // only the switch asks for Accessibility, not every slider move
            config = next
            reconfigure(prompt: turnedOn)
        case "setButton":
            guard let button = args.first as? String ?? (args.first as? NSNumber)?.stringValue, (Int(button) ?? 0) >= 2 else {
                return reply(nil, "Only the extra buttons (middle, back, forward…) can be remapped")
            }
            var next = config
            var json = next.buttons[button].flatMap { try? JSONEncoder().encode($0) }
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? ["click": "none", "hold": "none", "drag": "none"]
            for (k, v) in (args.dropFirst().first as? [String: Any]) ?? [:] where json[k] != nil { json[k] = v }
            if let data = try? JSONSerialization.data(withJSONObject: json), let rule = try? JSONDecoder().decode(MouseConfig.ButtonRule.self, from: data) {
                next.buttons[button] = rule
            }
            next.normalize()
            config = next
        case "removeButton":
            var next = config
            next.buttons[args.first as? String ?? ""] = nil
            config = next
        case "learn":
            setLearning(args.first as? Bool ?? false)
        case "openPrivacy":
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        default:
            return reply(nil, "Unknown mouse call: \(fn)")
        }
        reply(state(), nil)
    }

    private func setLearning(_ on: Bool) {
        learnTimeout?.cancel()
        lock.withLock { _learning = on }
        if on {
            let timeout = DispatchWorkItem { [weak self] in
                self?.lock.withLock { self?._learning = false }
                self?.reconfigure(prompt: false)
                PluginEvents.emit("mouse", ["learning": false], to: "mouse")
            }
            learnTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: timeout)
        }
        reconfigure(prompt: on)
    }

    private func state() -> [String: Any] {
        [
            "config": config.json,
            "trusted": AXIsProcessTrusted(),
            "running": isRunning,
            "error": lock.withLock { _error } as Any? ?? NSNull(),
            "learning": learning,
            "actions": MouseActions.all.map { ["id": $0.id, "label": $0.label] },
        ]
    }

    /// Tap thread → main: a button was pressed while learning.
    fileprivate func learned(button: Int64) {
        DispatchQueue.main.async { [self] in
            learnTimeout?.cancel()
            lock.withLock { _learning = false }
            reconfigure(prompt: false)
            PluginEvents.emit("mouse", ["learning": false, "button": button], to: "mouse")
        }
    }
}

/// Owns the event tap and its run loop. Everything inside runs on this thread.
private final class TapThread: Thread {
    private unowned let service: MouseFixService
    private let scroller: MouseScroller
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop? { get { loopLock.withLock { _runLoop } } set { loopLock.withLock { _runLoop = newValue } } }
    private var _runLoop: CFRunLoop?
    private let loopLock = NSLock()
    private let exited = DispatchSemaphore(value: 0)

    // Button gesture in progress (the button is held and swallowed until it's released)
    private var active: Int64?
    private var rule = MouseConfig.ButtonRule()
    private var holdTimer: CFRunLoopTimer?
    private var holdFired = false
    private var dragFired = false
    private var travelled = CGPoint.zero
    private var balance = MouseButtonBalance()
    private var frozen = false // we detached the pointer from the mouse and must give it back

    private static let holdDelay = 0.4
    private static let dragDistance = 50.0

    init(service: MouseFixService) {
        self.service = service
        scroller = MouseScroller { [unowned service] in service.config }
        super.init()
        name = "nook.mouse"
        qualityOfService = .userInteractive
    }

    /// Draining cancels actions and scrolling, but retains the tap to consume owed releases.
    func setWanted(_ wanted: Bool) {
        guard let runLoop else { return } // startup reads the current service state before running
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [weak self] in
            guard let self else { return }
            let wasDraining = balance.draining
            balance.setWanted(wanted)
            if wanted, let tap {
                guard CFMachPortIsValid(tap) else {
                    CFRunLoopStop(CFRunLoopGetCurrent())
                    return
                }
                CGEvent.tapEnable(tap: tap, enable: true)
                if wasDraining { service.report(running: true) }
            }
            if !wanted {
                endGesture()
                scroller.cancelScroll()
            }
            if balance.canStop { CFRunLoopStop(CFRunLoopGetCurrent()) }
        }
        CFRunLoopWakeUp(runLoop)
    }

    func stopAndWait() {
        cancel() // main() checks this before it starts running, so a thread that's still setting up won't run forever
        if let runLoop {
            // Queued, not stopped directly: a stop sent before the loop is running would be lost.
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { CFRunLoopStop(CFRunLoopGetCurrent()) }
            CFRunLoopWakeUp(runLoop)
        }
        if !isFinished { _ = exited.wait(timeout: .now() + 1) }
    }

    override func main() {
        defer { exited.signal() }
        guard !isCancelled else { return }
        let events: [CGEventType] = [.scrollWheel, .otherMouseDown, .otherMouseUp, .otherMouseDragged]
        let mask = events.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            return Unmanaged<TapThread>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            service.report(running: false, error: "Couldn't start the mouse event tap. Check Accessibility; Nook will retry automatically.")
            return
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        runLoop = CFRunLoopGetCurrent()
        CFRunLoopAddSource(runLoop, source, .commonModes)
        scroller.start()
        CGEvent.tapEnable(tap: tap, enable: true)
        service.report(running: true)
        balance.setWanted(service.config.enabled || service.learning)
        if !isCancelled && !balance.canStop { CFRunLoopRun() }

        service.report(running: false)
        endGesture()
        scroller.stop()
        CGEvent.tapEnable(tap: tap, enable: false)
        CFRunLoopRemoveSource(runLoop, source, .commonModes)
        CFMachPortInvalidate(tap)
    }

    // MARK: Events

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            cancelGesture()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        if event.getIntegerValueField(.eventSourceUserData) == MouseFixService.marker { return pass } // ours
        let config = service.config
        let wanted = config.enabled || service.learning
        // Observe settings here too: a release may beat the queued reconfiguration block.
        if !wanted, !balance.draining {
            balance.setWanted(false)
            endGesture()
            scroller.cancelScroll()
        }

        switch type {
        case .scrollWheel:
            return config.enabled && !balance.draining ? scroller.handle(event) : pass

        case .otherMouseDown:
            let button = event.getIntegerValueField(.mouseEventButtonNumber)
            // A repeat cannot turn a suppressed press into a visible one while draining.
            if balance.suppressed.contains(button) { return nil }
            guard !balance.draining else { return pass }
            if service.learning, balance.suppress(button) {
                service.learned(button: button)
                return nil
            }
            guard config.enabled, let rule = config.buttons[String(button)], rule.isActive,
                  balance.suppress(button) else { return pass }
            begin(button: button, rule: rule)
            return nil

        case .otherMouseDragged:
            let button = event.getIntegerValueField(.mouseEventButtonNumber)
            guard balance.suppressed.contains(button) else { return pass }
            if button == active {
                drag(dx: event.getDoubleValueField(.mouseEventDeltaX), dy: event.getDoubleValueField(.mouseEventDeltaY))
            }
            return nil

        case .otherMouseUp:
            let button = event.getIntegerValueField(.mouseEventButtonNumber)
            guard balance.release(button) else { return pass }
            if button == active { release() }
            if balance.canStop { CFRunLoopStop(CFRunLoopGetCurrent()) }
            return nil

        default:
            return pass
        }
    }

    // MARK: Button gestures

    private func begin(button: Int64, rule: MouseConfig.ButtonRule) {
        cancelGesture()
        active = button
        self.rule = rule
        holdFired = false
        dragFired = false
        travelled = .zero
        if rule.drag != "none" {
            CGAssociateMouseAndMouseCursorPosition(0) // pointer stays put while you drag
            frozen = true
        }
        if rule.hold != "none" {
            let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + Self.holdDelay, 0, 0, 0) { [weak self] _ in
                guard let self, service.config.enabled, !balance.draining,
                      active != nil, !dragFired, !holdFired else { return }
                holdFired = true
                MouseActions.run(self.rule.hold)
            }
            CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .commonModes)
            holdTimer = timer
        }
    }

    private func drag(dx: Double, dy: Double) {
        guard rule.drag == "spaces", !dragFired, !holdFired else { return }
        travelled.x += dx
        travelled.y += dy
        guard max(abs(travelled.x), abs(travelled.y)) >= Self.dragDistance else { return }
        dragFired = true
        // Like a three-finger swipe: right → the Space on the left, up → Mission Control, down → App Exposé.
        if abs(travelled.x) > abs(travelled.y) {
            MouseActions.run(travelled.x > 0 ? "spaceLeft" : "spaceRight")
        } else {
            MouseActions.run(travelled.y < 0 ? "missionControl" : "appExpose")
        }
    }

    private func release() {
        let fired = holdFired || dragFired
        let rule = rule
        let button = active ?? 2
        endGesture()
        guard !fired else { return }
        if rule.click != "none" {
            MouseActions.run(rule.click)
        } else {
            MouseActions.click(button: button) // a plain click on a button we only watched for hold/drag: give it back
        }
    }

    /// Abandon a gesture whose button is still down: its release must not reach apps without the press.
    private func cancelGesture() {
        // Balance owns all suppressed presses independently of the current gesture.
        endGesture()
    }

    /// Forget the gesture and give the pointer back.
    private func endGesture() {
        if let holdTimer { CFRunLoopTimerInvalidate(holdTimer) }
        holdTimer = nil
        active = nil
        if frozen {
            CGAssociateMouseAndMouseCursorPosition(1)
            frozen = false
        }
    }
}
