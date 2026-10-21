import AppKit

@main
struct IntegrationTests {
    static func main() throws {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message)
            checks += 1
        }
        NativeShortcutIntegration.register()
        NativeShortcutIntegration.registerWindows()
        let all = SettingsShortcutItem.all
        check(all.contains { $0.id == "extension:keyboard.openNook" && $0.get() != nil }, "Open Nook is registered with its default")
        check(all.filter { $0.group == "Window Management" }.count == WindowAction.allCases.count, "Every window action is registered, including unassigned ones")
        check(all.first { $0.id == "extension:keyboard.openNook" }?.defaultShortcut != nil, "Open Nook retains Restore Default")
        check(all.filter { $0.group == "Navigation" }.count == 17, "All fixed navigation bindings are listed")
        check(all.filter { $0.group == "Navigation" }.allSatisfy { !$0.editable }, "Fixed bindings are read-only")
        let open = all.first { $0.id == "extension:keyboard.openNook" }!
        let window = all.first { $0.id == "extension:windows.center" }!
        let tab = all.first { $0.id == "tab:notes" }!
        check(window.conflicts(with: open.get()!).contains { $0.id == open.id }, "Windows detect Open Nook")
        check(WindowShortcuts.shared.conflicts(OpenNookShortcut.current!, for: .center).contains { $0.contains("Open Nook") }, "Window execution refuses Open Nook collision")
        let chord = DictationShortcut(keyCode: 3, modifiers: CGEventFlags([.maskAlternate, .maskShift, .maskCommand]).rawValue, display: "⌥⇧⌘F")
        window.set(chord)
        check(tab.rejection(for: chord)?.contains("Center") == true, "Tabs reject window collisions")
        check(open.rejection(for: chord)?.contains("Center") == true, "Open Nook rejects window collisions")
        let navigation = TabNavigationStore.shared
        let group = try navigation.save(TabGroup(name: "Work", symbol: "briefcase", members: ["notes", "files"]), pluginIDs: Services.shared.plugins.tabs.map(\.id))
        let groupShortcut = SettingsShortcutItem.group(group)
        check(groupShortcut.rejection(for: chord)?.contains("Center") == true, "Groups reject window collisions")
        window.set(nil)
        groupShortcut.set(chord)
        check(window.rejection(for: chord)?.contains("Work") == true, "Windows reject group collisions")
        check(WindowShortcuts.shared.conflicts(TabHotkey(keyCode: chord.keyCode!, modifiers: chord.modifiers, display: chord.display), for: .center).contains { $0.contains("Work") }, "Window execution checks group shortcuts")
        check(NativeShortcutIntegration.group(key: 3, modifiers: CGEventFlags(rawValue: chord.modifiers))?.id == group.id, "Group hotkey routes by hardware key")
        let deck = DictationShortcut(keyCode: 123, modifiers: CGEventFlags([.maskAlternate, .maskCommand]).rawValue, display: "⌥⌘←")
        check(tab.rejection(for: deck)?.contains("Deck") == true, "Fixed deck navigation is reserved across recorders")
        let spotlight = DictationShortcut(keyCode: 49, modifiers: CGEventFlags.maskCommand.rawValue, display: "⌘Space")
        check(open.rejection(for: spotlight)?.contains("Spotlight") == true, "Known system bindings are blocked by all recorders")
        groupShortcut.set(nil)

        // Actual NotchViewModel, with inert services and geometry. No NSWindow or application is created.
        let vm = NotchViewModel(geometry: NotchGeometry())
        vm.open(tab: "notes")
        check(vm.tab == "notes" && vm.currentGroup?.id == group.id, "Direct member opens its deck without changing active plugin identity")
        check(vm.contentHeight == 300, "Active member controls height")
        let tall = vm.liveRect
        vm.select("files")
        check(vm.contentHeight == 120 && vm.isOpen, "Short member stays open")
        check(vm.holdRect?.contains(tall) == true, "Deck selection preserves tall holdRect")
        check(navigation.group(group.id)?.lastMember == "files", "Direct selection remembers last member")
        vm.holdRect = nil
        vm.stepDeck(-1)
        let deckTall = vm.liveRect
        vm.holdRect = nil
        vm.stepDeck(1)
        check(vm.tab == "files" && vm.holdRect?.contains(deckTall) == true, "Deck keyboard path preserves holdRect")
        vm.select("notes")
        vm.holdRect = nil
        vm.swipeTabs(1)
        check(vm.tab == "files" && vm.holdRect?.contains(deckTall) == true, "Deck swipe path preserves holdRect")
        navigation.moveMembers(group.id, from: IndexSet(integer: 0), to: 2)
        vm.select("notes")
        check(vm.slideEdge == .trailing, "Pill transitions follow reordered deck order")
        navigation.moveMembers(group.id, from: IndexSet(integer: 0), to: 2)
        vm.select("files")
        vm.select("home")
        vm.step(1)
        check(vm.tab == "files", "Dock cycling enters last group member")
        vm.step(1)
        check(vm.tab == "clips", "Control-Tab leaves a deck as one dock item")
        navigation.setHidden("files", true)
        vm.select("files")
        check(vm.isEnabled("files") && vm.currentTab?.id == "files", "Hidden member stays enabled and directly reachable")
        check(!vm.deckTabs.contains { $0.id == "files" }, "Hidden member is absent from deck cycling")
        check(vm.deckDisplayTabs.contains { $0.id == "files" }, "Directly opened hidden member retains a selected pill")
        let item = vm.dockItems.first { $0.id == group.id }!
        vm.selectDockItem(item)
        check(vm.tab == "notes", "Numbered/dock entry skips hidden last member")
        vm.select("files")
        vm.stepDeck(1)
        check(vm.tab == "notes", "Swipe from hidden member returns to visible member")
        navigation.setHidden("home", true)
        vm.open(tab: "home")
        check(vm.tab == "home", "Hidden standalone direct URL/agent path remains reachable")
        vm.step(1)
        check(vm.tab == "notes", "Cycling from hidden standalone starts at first dock item")
        let state = vm.keyboard
        check(state.results.contains { $0.id == "tab:home" && $0.shortcut.isEmpty }, "Palette includes hidden tab without incorrect numeric hint")
        check(state.results.contains { $0.id == group.id && $0.shortcut == "⌘1" }, "Palette numbers groups by dock position")
        check(state.results.first { $0.id == "tab:notes" }?.shortcut != "⌘1", "Palette member doesn't claim group's numeric key")
        vm.select("files")
        vm.close()
        vm.toggleGroup(group.id)
        check(vm.isOpen && vm.tab == "files", "Group hotkey can reopen a directly used hidden last member")
        vm.toggleGroup(group.id)
        check(!vm.isOpen, "Group hotkey toggles its current deck closed")
        groupShortcut.set(chord)
        UserDefaults.standard.set("notes,files", forKey: Prefs.disabledTabs)
        check(NativeShortcutIntegration.group(key: 3, modifiers: CGEventFlags(rawValue: chord.modifiers)) == nil, "Empty/disabled deck cannot route global hotkey")
        vm.open(tab: "notes")
        check(vm.tab == "home", "Disabled direct member falls back to enabled plugin")
        print("Passed \(checks) shortcut catalog/conflicts, palette, direct opens, deck navigation and holdRect integration checks")
    }
}
