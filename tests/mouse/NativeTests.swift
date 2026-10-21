import AppKit

@main
struct MouseTests {
    static func main() throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            checks += 1
        }

        // Learning while disabled consumes a complete pair, even if reconfiguration follows down.
        var learned = MouseButtonBalance()
        check(learned.suppress(3), "Learning owns the press")
        learned.setWanted(false)
        check(!learned.canStop, "Learning cannot stop its tap before release")
        check(!learned.suppress(4), "New buttons pass through during drain")
        check(!learned.release(4), "A passed-through press keeps its release")
        check(learned.release(3) && learned.canStop, "Learned release drains the tap")
        check(!learned.release(3), "Duplicate release is never swallowed")

        // More than two overlapping presses used to overwrite the single swallowUp slot.
        for order in [[2, 3, 4], [4, 2, 3], [3, 4, 2]] as [[Int64]] {
            var balance = MouseButtonBalance()
            for button in order { check(balance.suppress(button), "Own each overlapping down") }
            balance.setWanted(false) // disable mid hold/drag; gesture cancellation cannot clear the set
            check(balance.suppressed.count == 3 && !balance.canStop, "Cancellation retains every release")
            for (index, button) in order.reversed().enumerated() {
                check(balance.release(button), "Every suppressed button owns one up")
                check(balance.canStop == (index == 2), "Only the final release permits teardown")
            }
        }
        var resumed = MouseButtonBalance()
        check(!resumed.suppress(0) && !resumed.suppress(1), "Never capture left/right")
        check(resumed.suppress(2), "Middle down")
        resumed.setWanted(false); resumed.setWanted(true)
        check(resumed.suppress(4) && resumed.release(2) && resumed.release(4), "Reenable while draining retains balance")
        check(!resumed.canStop, "Reenabled tap remains wanted")

        // Exhaust every up ordering for four simultaneous physical buttons.
        func permutations(_ values: [Int64]) -> [[Int64]] {
            values.isEmpty ? [[]] : values.flatMap { v in permutations(values.filter { $0 != v }).map { [v] + $0 } }
        }
        for downs in permutations([2, 3, 4, 5]) {
            for ups in permutations(downs) {
                var balance = MouseButtonBalance()
                for button in downs { check(balance.suppress(button), "Permutation down") }
                balance.setWanted(false)
                for (index, button) in ups.enumerated() {
                    check(balance.release(button), "Permutation up")
                    check(balance.canStop == (index == 3), "No early teardown")
                }
            }
        }

        // Reversal is not chatter unless the user explicitly opts in. Check both axes and signs.
        for sign in [-1.0, 1.0] {
            for gap in [0.0, 0.001, 0.05, 0.099, 0.1, 0.5] {
                check(!MouseWheelReversal.shouldFilter(dy: -sign, dx: 0, remainingY: sign * 100,
                                                       remainingX: 0, gap: gap, filterChatter: false),
                      "Default preserves even the fastest intentional reversal")
                check(!MouseWheelReversal.shouldFilter(dy: 0, dx: -sign, remainingY: 0,
                                                       remainingX: sign * 100, gap: gap, filterChatter: false),
                      "Horizontal reversals are preserved")
                check(MouseWheelReversal.shouldFilter(dy: -sign, dx: 0, remainingY: sign * 100,
                                                      remainingX: 0, gap: gap, filterChatter: true) == (gap < 0.1),
                      "Opt-in chatter filter has an explicit window")
            }
            var remaining = sign * 100, carry = sign * 0.9, lines = sign * 0.3
            MouseWheelReversal.prepare(delta: -sign, remaining: &remaining, carry: &carry, lineCarry: &lines)
            check(remaining == 0 && carry == 0 && lines == 0, "Reversal clears old glide and fractions")
            remaining += -sign * 70
            MouseWheelReversal.prepare(delta: -sign, remaining: &remaining, carry: &carry, lineCarry: &lines)
            check(remaining == -sign * 70, "Same direction keeps its pool")
        }
        let oldConfig = try JSONDecoder().decode(MouseConfig.self, from: Data("{\"enabled\":true}".utf8))
        check(oldConfig.enabled && !oldConfig.filterChatter, "Existing preferences opt out of filtering")
        check(oldConfig.merging(["filterChatter": true])?.filterChatter == true, "Chatter option merges through bridge settings")
        check(oldConfig.merging(["filterChatter": "bad"]) == nil, "Invalid filter type rejects")

        // Call the actual hotkey processor with in-memory events. No tap installation or event posting.
        let hotkeys = HotkeyMonitor()
        hotkeys.toggle = nil; hotkeys.hold = nil
        var shortcuts = 0
        hotkeys.onShortcut = { _, _ in shortcuts += 1; return true }
        func key(_ down: Bool, synthetic: Bool) -> CGEvent {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: 8, keyDown: down)!
            event.flags = .maskCommand
            if synthetic { event.setIntegerValueField(.eventSourceUserData, value: NookSyntheticInput.mouseMarker) }
            return event
        }
        check(hotkeys.handle(.keyDown, key(true, synthetic: false)) == nil && shortcuts == 1,
              "Physical shortcut still fires and is swallowed")
        check(hotkeys.handle(.keyDown, key(true, synthetic: true)) != nil && shortcuts == 1,
              "Synthetic copy does not invoke a shortcut")
        check(hotkeys.handle(.keyUp, key(false, synthetic: true)) != nil,
              "Synthetic release passes even while same physical key is swallowed")
        check(hotkeys.handle(.keyUp, key(false, synthetic: false)) == nil,
              "Synthetic release did not clear the physical shortcut's release state")
        hotkeys.hold = .defaultHold
        var started = 0, cancelled = 0, ended = 0
        hotkeys.onHoldStart = { started += 1 }; hotkeys.onHoldCancel = { cancelled += 1 }; hotkeys.onHoldEnd = { ended += 1 }
        let flags = CGEvent(source: nil)!
        flags.flags = [.maskControl, .maskAlternate]
        _ = hotkeys.handle(.flagsChanged, flags)
        _ = hotkeys.handle(.keyDown, key(true, synthetic: true))
        flags.flags = []
        _ = hotkeys.handle(.flagsChanged, flags)
        check(started == 1 && ended == 1 && cancelled == 0, "Synthetic keys leave dictation hold state intact")
        print("PASS: \(checks) mouse balance, reversal, config migration and synthetic-hotkey checks; no events posted")
    }
}
