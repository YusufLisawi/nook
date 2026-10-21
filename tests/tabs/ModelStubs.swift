import Foundation

// TabHotkey has a native recorder; the pure model only depends on its serialized value.
struct TabHotkey: Codable, Equatable {
    var keyCode: Int
    var modifiers: UInt64
    var display: String
}
extension Notification.Name { static let nookShortcutsChanged = Notification.Name("nookShortcutsChanged") }
