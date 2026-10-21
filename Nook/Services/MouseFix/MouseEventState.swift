import Foundation

/// Physical presses hidden from applications must own their releases, even after a mode change.
/// Kept independent of event taps so overlap and teardown can be tested without posting input.
struct MouseButtonBalance {
    private(set) var suppressed: Set<Int64> = []
    private(set) var draining = false

    var canStop: Bool { draining && suppressed.isEmpty }

    mutating func setWanted(_ wanted: Bool) { draining = !wanted }

    /// False means a new physical press must pass through while the tap drains old releases.
    mutating func suppress(_ button: Int64) -> Bool {
        guard !draining, button >= 2 else { return false }
        suppressed.insert(button)
        return true
    }

    mutating func release(_ button: Int64) -> Bool { suppressed.remove(button) != nil }
}

/// Reversing one axis discards its old glide and fractional pixels, never the other axis.
/// Optional chatter filtering is deliberately off by default: fast reversals can be intentional.
enum MouseWheelReversal {
    static func shouldFilter(dy: Double, dx: Double, remainingY: Double, remainingX: Double,
                             gap: TimeInterval, filterChatter: Bool) -> Bool {
        filterChatter && gap >= 0 && gap < 0.1 &&
            ((dy != 0 && remainingY * dy < 0) || (dx != 0 && remainingX * dx < 0))
    }

    static func prepare(delta: Double, remaining: inout Double, carry: inout Double, lineCarry: inout Double) {
        if delta != 0, remaining * delta < 0 {
            remaining = 0
            carry = 0
            lineCarry = 0
        }
    }
}
