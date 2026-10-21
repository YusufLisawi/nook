import AppKit

@main struct LauncherInteractionTests {
    static func main() {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) { precondition(value(), message); checks += 1 }
        func key(_ code: UInt16, _ characters: String = "", _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                             characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
        }
        func until(_ ready: () -> Bool) {
            let end = Date().addingTimeInterval(1)
            while !ready(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.002)) }
            check(ready(), "Answer delivery timed out")
        }
        Prefs.registerDefaults(); UserDefaults.standard.set(false, forKey: Prefs.haptics)
        LauncherPreferences.set(.askAI, enabled: true)
        let vm = NotchViewModel(geometry: NotchGeometry())
        let search = LauncherFeature.shared.state(for: vm)
        search.present(); vm.open(); search.query = "200 + 12"
        until { search.smartAnswer != nil }
        check(search.smartAnswer?.copyValue == "212", "Answer is delivered")
        check(search.smartAnswerSelected && search.selectedIndex == -1, "Answer defaults to selection")
        check(search.results.last?.id == "askAI", "Normal results stay visible below the answer")
        check(search.visibleResultCount <= 5 && vm.launcherHeight <= 560, "Height includes card and bounds normal rows")
        _ = search.handle(key(125)); check(search.selectedIndex == 0 && !search.smartAnswerSelected, "Down reaches normal results")
        _ = search.handle(key(126)); check(search.smartAnswerSelected, "Up returns to card")
        _ = search.handle(key(40, "k", .command)); check(search.actionsPresented && search.actionIndex == 0, "Command-K opens answer actions")
        _ = search.handle(key(125)); check(search.actionIndex == 1, "Actions navigate independently of results")
        _ = search.handle(key(125)); check(search.actionIndex == 2, "Copy with units is keyboard reachable")
        _ = search.handle(key(125)); check(search.actionIndex == 0, "Answer actions wrap")
        search.escape(); check(!search.actionsPresented && search.smartAnswerSelected, "Escape closes actions first")
        _ = search.handle(key(36)); check(AnswerInteractionRecorder.calls.last?.paste == false, "Return requests copy")
        check(!vm.launcherPresented, "Copy dismisses")
        search.present(); vm.open(); search.query = "255 in hex"
        until { search.smartAnswer != nil }
        _ = search.handle(key(36, "", .command)); check(AnswerInteractionRecorder.calls.last?.paste == true, "Command Return requests paste")
        search.present(); vm.open(); search.query = "200 + 12"
        until { search.smartAnswer != nil }
        _ = search.handle(key(40, "k", .command)); _ = search.handle(key(125)); _ = search.handle(key(36))
        check(AnswerInteractionRecorder.calls.last?.action?.value == .copy("200 + 12"), "Actions Return copies expression")
        search.present(); vm.open(); search.query = "200 + 12"
        search.query = "notes"
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        check(search.smartAnswer == nil && search.selectedIndex >= 0, "Stale answer cannot replace a new search")
        search.query = "app: 200 + 12"
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        check(search.smartAnswer == nil, "Source prefixes exclude smart answers")
        search.query = "200 + 12"
        until { search.smartAnswer != nil }
        search.escape(); check(search.smartAnswer == nil && search.query.isEmpty, "Clearing query removes the card instantly")
        search.query = "200 + 12"; search.dismiss()
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        check(search.smartAnswer == nil && !vm.launcherPresented, "Closed launcher cannot receive late answers")
        check(AnswerInteractionRecorder.calls.count == 3, "Only explicit activation requests output")
        print("Passed \(checks) answer selection, resize, actions, copy/paste routing, Escape and stale-completion checks with inert output")
    }
}
