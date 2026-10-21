import Foundation

enum Prefs {
    static let openOnHover = "openOnHover"
    static let haptics = "hapticFeedback"
    static let hideInFullscreen = "hideInFullscreen"
    static let showMusic = "showMusicActivity"
    static let showTimer = "showTimerActivity"
    static let shelfAutoOpen = "shelfAutoOpenOnDrag"
    static let preferredScreen = "preferredScreenName"
    static let disabledTabs = "disabledTabs"
    static let hiddenTabs = "hiddenTabs" // [plugin ID]; presentation only, never disables a plugin
    static let tabGroups = "tabGroups" // JSON-encoded [TabGroup]
    static let dockOrder = "dockItemOrder" // plugin IDs and group:<UUID> IDs
    static let scratch = "scratch"
    static let swipes = "trackpadSwipes"
    static let openNookShortcut = "openNookShortcut" // TabHotkey JSON data; empty data = disabled

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            openOnHover: true, haptics: true, hideInFullscreen: true,
            showMusic: true, showTimer: true, shelfAutoOpen: true, swipes: true,
            preferredScreen: "*", disabledTabs: "", // every screen by default
        ])
    }

    static func bool(_ key: String) -> Bool { UserDefaults.standard.bool(forKey: key) }

    static var disabledTabSet: Set<String> {
        Set((UserDefaults.standard.string(forKey: disabledTabs) ?? "").split(separator: ",").map(String.init))
    }
}
