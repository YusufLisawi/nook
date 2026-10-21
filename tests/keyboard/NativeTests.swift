import AppKit

@main struct KeyboardTests {
    static func main() {
        let actions = KeyboardActions.shared
        actions.start()
        func register(_ rows: [[String: Any]], owner: String = "display-a", plugin: String = "notes", expectError: Bool = false) {
            var replied = false
            precondition(BridgeRegistry.handle("actions.register", args: [rows, owner], pluginID: plugin) { _, error in
                precondition((error != nil) == expectError)
                replied = true
            })
            precondition(replied)
        }
        register([["id": "new", "title": "New note", "shortcut": "⌘N"]])
        register([["id": "search", "title": "Search notes"]], owner: "display-b")
        precondition(actions.actions.count == 2)
        register([["id": "new", "title": "New note"], ["id": "new", "title": "Duplicate"]], expectError: true)
        precondition(actions.actions.count == 2)
        register([["id": "", "title": "Missing id"]], expectError: true)
        register([["id": "invalid", "title": "   "]], expectError: true)
        register((0..<101).map { ["id": "\($0)", "title": "Action"] }, expectError: true)
        register([["id": "updated", "title": "Updated note"]])
        precondition(actions.actions.count == 2 && actions.actions.contains { $0.id == "updated" })
        register([["id": "other", "title": "Other tab action"]], plugin: "home")
        register([["id": "disabled", "title": "Hidden action"]], plugin: "disabled")
        Services.shared.plugins.tabs = [.init(id: "home", name: "Home", height: 210), .init(id: "notes", name: "Notes", height: 210)]
        let vm = NotchViewModel(geometry: NotchGeometry())
        Services.shared.commands.commands = [AICommands.Command(id: "ai", name: "Summarize"), AICommands.Command(id: "off", name: "Disabled", enabled: false)]
        let state = vm.keyboard
        precondition(state.results.count == 5) // 2 tabs, 1 AI command, 2 actions on this display
        precondition(!state.results.contains { $0.title == "Search notes" || $0.title == "Hidden action" || $0.title == "Disabled" })
        state.move(-1)
        precondition(state.selectedIndex == 4)
        state.query = "qqq"
        precondition(state.selectedIndex == 0)
        precondition(state.results.isEmpty)
        state.query = "smmrz"
        precondition(state.results.map(\.title) == ["Summarize"])
        state.query = "zzzz"
        state.move(1)
        precondition(state.selected == nil)
        register([])
        precondition(actions.actions.filter { $0.pluginID == "notes" && $0.ownerID == "display-a" }.isEmpty)
        actions.remove(ownerID: "display-b")
        precondition(!actions.actions.contains { $0.ownerID == "display-b" })
        precondition(KeyboardSearch.score("cafe", in: "Café") != nil)
        precondition(KeyboardSearch.score("np", in: "Now Playing") != nil)
        precondition(KeyboardSearch.score("wrong", in: "Notes") == nil)
        precondition(KeyboardSearch.score("", in: "") == 0)
        func event(_ flags: NSEvent.ModifierFlags, chars: String = "f", code: UInt16 = 3) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
        }
        precondition(KeyboardActions.matches("⌘F", event: event(.command)))
        precondition(KeyboardActions.matches("Cmd+Shift+F", event: event([.command, .shift])))
        precondition(!KeyboardActions.matches("⌘F", event: event([.command, .option])))
        precondition(!KeyboardActions.matches("F", event: event([])))
        precondition(!KeyboardActions.matches("Shift+F", event: event(.shift)))
        precondition(KeyboardActions.matches("Cmd+Space", event: event(.command, chars: " ", code: 49)))
        let shortcut = OpenNookShortcut.defaultShortcut
        precondition(shortcut.keyCode == 49)
        precondition(shortcut.modifiers != CGEventFlags.maskCommand.rawValue)
        precondition(shortcut.modifiers != CGEventFlags([.maskCommand, .maskAlternate]).rawValue)
        let json = try! JSONEncoder().encode(shortcut)
        precondition(try! JSONDecoder().decode(TabHotkey.self, from: json) == shortcut)
        precondition(BridgeRegistry.javascript.contains("register"))
        print("PASS native: action validation/replacement/display ownership/cleanup; palette filtering, fuzzy search, selection; shortcut matching and safe default (\(shortcut.display))")
    }
}
