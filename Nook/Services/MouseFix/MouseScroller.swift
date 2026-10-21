import CoreGraphics
import CoreVideo
import Foundation

/// Turns a mouse wheel's clicks into smooth, pixel-based scrolling.
///
/// Every click adds distance to a pool; each frame moves a slice of what's left, so the scroll eases out. A click
/// the other way drops the pool, so scrolling reverses at once. Trackpads and Magic Mouse send continuous events,
/// which are left alone.
///
/// Output is plain pixel scroll events with no gesture/momentum phases: apps handle those as ordinary scrolling, and
/// there's no phase state for an app to get confused by when you scroll fast or change your mind mid-glide.
///
/// State is only touched from the event tap's thread; the display link just hands frames over to it.
final class MouseScroller {
    private let config: () -> MouseConfig
    private var remainingY = 0.0, remainingX = 0.0
    private var carryY = 0.0, carryX = 0.0 // fractions of a pixel not yet sent
    private var scrolling = false
    private var lineCarryY = 0.0, lineCarryX = 0.0 // fractions of a line not yet sent
    private let source = CGEventSource(stateID: .hidSystemState)
    private var lastTick: CFAbsoluteTime = 0
    private var tickRate = 0.0 // wheel clicks per second, smoothed
    private var lastFrame: CFAbsoluteTime = 0
    private var flags: CGEventFlags = []
    private var frames: CVDisplayLink? // ticks once per screen refresh, so apps get one event per frame
    private var framePending = false
    private let pendingLock = NSLock()

    private static let pixelsPerTick = 70.0
    private static let bounceWindow = 0.1 // seconds
    private static let maxTicksPerEvent = 6.0 // the system bundles fast spins into bigger deltas; cap a runaway wheel

    init(config: @escaping () -> MouseConfig) { self.config = config }

    /// Call on the thread whose run loop drives the animation.
    func start() {
        guard let runLoop = CFRunLoopGetCurrent() else { return }
        var link: CVDisplayLink?
        guard CVDisplayLinkCreateWithActiveCGDisplays(&link) == kCVReturnSuccess, let link else { return }
        // The display link calls from its own thread; hop back so all state stays on this one.
        CVDisplayLinkSetOutputHandler(link) { [weak self] _, _, _, _, _ in
            self?.requestFrame(on: runLoop)
            return kCVReturnSuccess
        }
        frames = link
    }

    func stop() {
        if let frames { CVDisplayLinkStop(frames) }
        frames = nil
    }

    private func requestFrame(on runLoop: CFRunLoop) {
        pendingLock.lock()
        let skip = framePending // a frame is already queued; don't pile up
        framePending = true
        pendingLock.unlock()
        guard !skip else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [weak self] in
            guard let self else { return }
            pendingLock.lock(); framePending = false; pendingLock.unlock()
            step()
        }
        CFRunLoopWakeUp(runLoop)
    }

    /// Drive the animation from the screen the pointer is on. False if frames can't be produced.
    private func startFrames() -> Bool {
        guard let frames else { return false }
        if CVDisplayLinkIsRunning(frames) { return true }
        var display = CGDirectDisplayID(), count: UInt32 = 0
        CGGetDisplaysWithPoint(CGEvent(source: nil)?.location ?? .zero, 1, &display, &count)
        if count > 0 { CVDisplayLinkSetCurrentCGDisplay(frames, display) }
        return CVDisplayLinkStart(frames) == kCVReturnSuccess
    }

    private func stopFrames() {
        if let frames, CVDisplayLinkIsRunning(frames) { CVDisplayLinkStop(frames) }
    }

    // MARK: Input

    /// Returns nil when the event was consumed, or the event (possibly edited) to pass on.
    func handle(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        guard event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0 else { return Unmanaged.passUnretained(event) }
        let c = config()
        var outFlags = event.flags

        var dy = Self.ticks(event, axis: 1), dx = Self.ticks(event, axis: 2)
        let swapAxes = Self.active(c.horizontalModifier, in: outFlags)
        if swapAxes {
            swap(&dy, &dx)
            outFlags.subtract(Self.mask(c.horizontalModifier))
        }
        var factor = c.speed
        if Self.active(c.preciseModifier, in: outFlags) {
            factor *= 0.25
            outFlags.subtract(Self.mask(c.preciseModifier))
        }
        if Self.active(c.quickModifier, in: outFlags) {
            factor *= 3
            outFlags.subtract(Self.mask(c.quickModifier))
        }
        if c.reverse { dy = -dy; dx = -dx }

        // Without smoothing, or if frames can't be produced, hand the wheel's own event on (edited) rather than eat it.
        guard c.smoothness != "off", startFrames() else {
            return passThrough(event, swapAxes: swapAxes, reverse: c.reverse, factor: factor, flags: outFlags)
        }

        let now = CFAbsoluteTimeGetCurrent()
        let gap = now - lastTick
        // A wheel chatters when it's spun hard and let go: a click the other way within a split second of the last one is
        // a bounce, not you changing your mind. Swallow it instead of stopping the glide dead.
        let reversing = (dy != 0 && remainingY * dy < 0) || (dx != 0 && remainingX * dx < 0)
        if reversing, gap < Self.bounceWindow { return nil }
        lastTick = now
        tickRate = gap > 0.4 ? 0 : tickRate * 0.6 + min(60, 1 / max(gap, 0.001)) * 0.4
        let boost = 1 + c.acceleration * 3 * min(1, max(0, (tickRate - 6) / 24))
        let distance = Self.pixelsPerTick * factor * boost

        if dy != 0 {
            if remainingY * dy < 0 { remainingY = 0 }
            remainingY += max(-Self.maxTicksPerEvent, min(Self.maxTicksPerEvent, dy)) * distance
        }
        if dx != 0 {
            if remainingX * dx < 0 { remainingX = 0 }
            remainingX += max(-Self.maxTicksPerEvent, min(Self.maxTicksPerEvent, dx)) * distance
        }
        flags = outFlags
        if !scrolling {
            scrolling = true
            carryY = 0; carryX = 0
            lineCarryY = 0; lineCarryX = 0
            lastFrame = now
        }
        return nil
    }

    /// Smoothing off: keep the wheel's own events, only swapping, flipping and scaling them.
    private func passThrough(_ event: CGEvent, swapAxes: Bool, reverse: Bool, factor: Double, flags: CGEventFlags) -> Unmanaged<CGEvent>? {
        let flip = reverse ? -1.0 : 1.0
        func line(_ v: Int64) -> Int64 {
            guard v != 0 else { return 0 }
            let n = (Double(v) * flip * factor).rounded()
            return Int64(n == 0 ? flip * Double(v.signum()) : n) // a click always moves at least one line
        }
        func point(_ v: Int64) -> Int64 { Int64((Double(v) * flip * factor).rounded()) }

        var lines = (y: event.getIntegerValueField(.scrollWheelEventDeltaAxis1), x: event.getIntegerValueField(.scrollWheelEventDeltaAxis2))
        var points = (y: event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), x: event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))
        var fixed = (y: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1), x: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2))
        if swapAxes { swap(&lines.y, &lines.x); swap(&points.y, &points.x); swap(&fixed.y, &fixed.x) }

        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: line(lines.y))
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: line(lines.x))
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: point(points.y))
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: point(points.x))
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: fixed.y * flip * factor)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: fixed.x * flip * factor)
        event.flags = flags
        return Unmanaged.passUnretained(event)
    }

    // MARK: Animation

    private func step() {
        guard scrolling else { return }
        let now = CFAbsoluteTimeGetCurrent()
        let dt = min(0.05, now - lastFrame)
        lastFrame = now
        let tau = Self.tau(config().smoothness)
        let k = tau > 0 ? 1 - exp(-dt / tau) : 1

        var moveY = remainingY * k, moveX = remainingX * k
        remainingY -= moveY
        remainingX -= moveX
        let done = abs(remainingY) < 0.4 && abs(remainingX) < 0.4
        if done {
            moveY += remainingY; moveX += remainingX
            remainingY = 0; remainingX = 0
        }
        let totalY = moveY + carryY, totalX = moveX + carryX
        let sendY = totalY.rounded(.towardZero), sendX = totalX.rounded(.towardZero)
        carryY = totalY - sendY
        carryX = totalX - sendX
        if sendY != 0 || sendX != 0 { post(dy: sendY, dx: sendX) }
        if done {
            scrolling = false
            stopFrames()
        }
    }

    /// One frame of scrolling. A real wheel event carries the distance three ways (pixels, lines, fixed-point
    /// lines) and apps read whichever they like, so fill in all three; a line is about 10 pixels.
    private func post(dy: Double, dx: Double) {
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                  wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0) else { return }
        let linesY = dy / 10 + lineCarryY, linesX = dx / 10 + lineCarryX
        let wholeY = linesY.rounded(.towardZero), wholeX = linesX.rounded(.towardZero)
        lineCarryY = linesY - wholeY
        lineCarryX = linesX - wholeX
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(dy))
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(dx))
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: Int64(wholeY))
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: Int64(wholeX))
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: dy / 10)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: dx / 10)
        event.flags = flags
        event.setIntegerValueField(.eventSourceUserData, value: MouseFixService.marker)
        event.post(tap: .cgSessionEventTap)
    }

    // MARK: Helpers

    /// Wheel clicks on one axis (axis 1 = vertical, 2 = horizontal), signed.
    private static func ticks(_ event: CGEvent, axis: Int) -> Double {
        let line = event.getIntegerValueField(axis == 1 ? .scrollWheelEventDeltaAxis1 : .scrollWheelEventDeltaAxis2)
        if line != 0 { return Double(line) }
        let point = event.getIntegerValueField(axis == 1 ? .scrollWheelEventPointDeltaAxis1 : .scrollWheelEventPointDeltaAxis2)
        return Double(point.signum())
    }

    /// Seconds for the scroll to get ~63% of the way: higher = longer glide.
    private static func tau(_ smoothness: String) -> Double {
        switch smoothness {
        case "low": 0.07
        case "high": 0.2
        case "off": 0
        default: 0.12
        }
    }

    private static func mask(_ name: String) -> CGEventFlags {
        switch name {
        case "shift": .maskShift
        case "option": .maskAlternate
        case "control": .maskControl
        case "command": .maskCommand
        default: []
        }
    }

    private static func active(_ name: String, in flags: CGEventFlags) -> Bool {
        let m = mask(name)
        return !m.isEmpty && flags.contains(m)
    }
}
