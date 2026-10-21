import AppKit

/// One catalog for native hotkeys, including fixed in-notch navigation reservations.
enum NativeShortcutIntegration {
    static func register() {
        ShortcutRegistry.register(id: "keyboard.openNook", title: "Open Nook", group: "Nook",
                                  defaultShortcut: OpenNookShortcut.defaultShortcut,
                                  get: { OpenNookShortcut.current }, set: { OpenNookShortcut.save($0) })
        registerNavigation()
    }

    private static func registerNavigation() {
        let command = CGEventFlags.maskCommand
        let control = CGEventFlags.maskControl
        var fixed: [(String, String, Int, CGEventFlags, String)] = [
            ("palette", "Command Palette", 40, command, "⌘K"),
            ("next", "Next Dock Item", 48, control, "⌃Tab"),
            ("previous", "Previous Dock Item", 48, [control, .maskShift], "⌃⇧Tab"),
            ("nextBracket", "Next Dock Item (alternate)", 30, command, "⌘]"),
            ("previousBracket", "Previous Dock Item (alternate)", 33, command, "⌘["),
            ("deckPrevious", "Previous Deck Member", 123, [command, .maskAlternate], "⌥⌘←"),
            ("deckNext", "Next Deck Member", 124, [command, .maskAlternate], "⌥⌘→"),
            ("escape", "Dismiss Palette / Close Nook", 53, [], "Esc"),
        ]
        for (index, code) in [18, 19, 20, 21, 23, 22, 26, 28, 25].enumerated() {
            fixed.append(("dock\(index + 1)", "Dock Item \(index + 1)", code, command, "⌘\(index + 1)"))
        }
        for (id, title, key, flags, display) in fixed {
            let shortcut = TabHotkey(keyCode: key, modifiers: flags.rawValue, display: display)
            ShortcutRegistry.register(id: "navigation.\(id)", title: title, group: "Navigation", editable: false,
                                      get: { shortcut }, set: { _ in })
        }
        ShortcutRegistry.externalConflicts = SystemShortcutConflicts.systemConflicts
    }

    static func group(key: Int64, modifiers: CGEventFlags) -> TabGroup? {
        TabNavigationStore.shared.groups.first { group in
            group.hotkey?.keyCode == Int(key) && group.hotkey?.modifiers == modifiers.rawValue &&
            group.members.contains { id in Features.shared.tabEnabled(id) && Services.shared.plugins.tabs.contains { $0.id == id } }
        }
    }
}
