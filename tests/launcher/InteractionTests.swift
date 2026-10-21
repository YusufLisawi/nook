import AppKit

@main
struct InteractionTests {
    static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError(message) }
            checks += 1
        }
        func key(_ code: UInt16, _ chars: String = "", _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                             context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
        }
        func drain() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        Prefs.registerDefaults()
        UserDefaults.standard.set(false, forKey: Prefs.haptics)
        Services.shared.commands.commands = [.init(id: "rewrite", name: "Rewrite")]
        let vm = NotchViewModel(geometry: NotchGeometry())
        let state = LauncherFeature.shared.state(for: vm)
        var opened: [String] = []
        vm.keyboardRun = { entry, _ in opened.append(entry.id) }
        state.present(); vm.open()
        check(AICommandContext.captures == 1, "Capture context on open")
        check(vm.launcherPresented && vm.keyboard.engaged, "Open launcher as a keyboard notch mode")
        check(vm.contentSize.width == 720 && vm.contentSize.height <= 560, "Launcher fits existing panel")
        vm.hoverEnded()
        check(vm.isOpen, "Pointer leaving doesn't close launcher")
        check(state.results.contains { $0.id == "command:rewrite" }, "AI commands join results")
        state.query = "home"
        check(state.results.first?.title == "Home", "Nook tabs use shared palette entries")
        check(state.results.last?.id == "askAI", "Ask AI stays final")
        _ = state.handle(key(125)); check(state.selectedIndex == 1, "Down selects next")
        _ = state.handle(key(35, "p", .control)); check(state.selectedIndex == 0, "Control-P selects previous")
        _ = state.handle(key(45, "n", .control)); check(state.selectedIndex == 1, "Control-N selects next")
        _ = state.handle(key(126)); check(state.selectedIndex == 0, "Up selects previous")
        _ = state.handle(key(40, "k", .command)); check(state.actionsPresented, "Command-K opens row actions")
        state.escape(); check(!state.actionsPresented && state.query == "home", "Escape dismisses actions first")
        _ = state.handle(key(36)); check(opened == ["tab:home"] && !vm.launcherPresented, "Return opens tab")
        check(LauncherFeature.shared.history["tab:home"]?.count == 1, "Successful launches update frecency")
        state.present(); vm.open(); state.query = "rewrite"
        _ = state.handle(key(36)); check(AICommands.capturedRuns == ["rewrite"], "AI command receives captured context")
        state.present(); vm.open(); state.query = "notes"
        _ = state.handle(key(18, "1", .command)); check(opened.last == "tab:notes", "Command-1 picks result instead of dock item")
        state.present(); vm.open(); state.query = "missing xyz"
        check(state.results.count == 1 && state.results[0].id == "askAI", "Unmatched query retains AI escape hatch")
        LauncherPreferences.set(.askAI, enabled: false)
        state.query = "missing xyz"
        check(state.results.isEmpty && !state.canAskAI, "Quick AI source toggle respected")
        LauncherPreferences.set(.applications, enabled: false)
        LauncherApplicationIndex.shared.applications = [.init(path: "/tmp/Test.app", name: "Test", bundleID: "test")]
        drain(); state.query = "app: test"
        check(state.results.isEmpty, "Disabled application source excluded")
        LauncherPreferences.set(.applications, enabled: true)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: nil)
        drain(); state.query = "app: test"
        check(state.results.first?.title == "Test", "Source prefix selects apps")
        state.escape(); check(state.query.isEmpty && vm.isOpen, "Escape clears text first")
        state.escape(); check(!vm.isOpen && !vm.launcherPresented, "Second Escape closes")
        state.present(); vm.open(); state.query = "empty trash"
        guard let trash = state.results.first else { fatalError("Missing Empty Trash") }
        state.run(trash)
        check(state.confirmation == trash.id && Shell.calls.isEmpty, "Trash requires explicit inline confirmation")
        state.escape(); check(state.confirmation == nil && vm.isOpen, "Escape cancels confirmation")
        state.run(trash); state.run(trash)
        check(Shell.calls.count == 1 && Shell.calls[0].contains("Finder"), "Confirmed Trash uses Finder")
        state.run(trash); check(Shell.calls.count == 1, "Busy system command cannot be duplicated")
        Shell.completions[0](["code": 1, "stderr": "Denied"]); drain()
        check(state.error == "Denied" && !state.performing, "System failures remain inline")
        state.run(trash); state.run(trash); check(Shell.calls.count == 2, "Can retry confirmed command")
        state.dismiss()
        Shell.completions[1](["code": 1, "stderr": "Stale"]); drain()
        check(!vm.launcherPresented, "Late completion doesn't reopen closed launcher")
        LauncherFeature.shared.clearHistory(); check(LauncherFeature.shared.history.isEmpty, "Clear recents")
        check(LauncherShortcut.defaultShortcut?.keyCode == 49, "Default uses Space")
        LauncherShortcut.save(TabHotkey(keyCode: 49, modifiers: CGEventFlags.maskAlternate.rawValue, display: "Custom label"))
        check(LauncherShortcut.matches(key: 49, modifiers: .maskAlternate), "Shortcut matching ignores display label")
        LauncherShortcut.save(nil); check(!LauncherShortcut.matches(key: 49, modifiers: .maskAlternate), "Shortcut can be disabled")
        state.present(); vm.open(); state.query = ""
        let launcherRect = vm.liveRect
        vm.select("files")
        check(!vm.launcherPresented && vm.isOpen, "Direct tab open leaves launcher mode")
        check(vm.holdRect?.contains(launcherRect) == true, "Direct tab open retains the launcher's old hit rectangle")
        vm.close()
        let option = TabHotkey(keyCode: 49, modifiers: CGEventFlags.maskAlternate.rawValue, display: "Different display label")
        TabHotkeys.set("home", option)
        check(LauncherShortcut.defaultShortcut?.modifiers == CGEventFlags([.maskControl, .maskAlternate]).rawValue, "Occupied Option-Space falls back regardless of display label")
        TabHotkeys.set("notes", TabHotkey(keyCode: 49, modifiers: CGEventFlags([.maskControl, .maskAlternate]).rawValue, display: "Control Option Space"))
        check(LauncherShortcut.defaultShortcut == nil, "Both occupied defaults leave launcher unassigned")
        TabHotkeys.set("home", nil); TabHotkeys.set("notes", nil)
        DictationShortcut.save(DictationService.Keys.toggleShortcut, nil)
        check(LauncherShortcut.defaultShortcut?.modifiers == CGEventFlags.maskAlternate.rawValue, "Disabled dictation frees Option-Space before dictation service starts")
        DictationShortcut.save(DictationService.Keys.toggleShortcut, .defaultToggle)
        check(LauncherShortcut.defaultShortcut?.modifiers == CGEventFlags([.maskControl, .maskAlternate]).rawValue, "Persisted dictation shortcut is checked before service startup")
        LauncherPreferences.set(.askAI, enabled: true)
        state.present(); vm.open(); state.query = "Explain this literal $(query)"
        _ = state.handle(key(48)); drain()
        check(state.chatQuery == "Explain this literal $(query)", "Tab opens native Quick AI when no agent exists")
        check(state.answer == "Reply: Explain this literal $(query)" && !state.thinking, "Native Quick AI streams the literal query through the AI pipeline")
        state.escape(); check(state.chatQuery == nil && vm.isOpen, "Escape backs out of Quick AI to search")
        state.escape(); state.escape()
        print("Passed \(checks) launcher mode, keyboard, source, confirmation, persistence and lifecycle checks without launching Nook")
    }
}
