import AppKit

/// Native extensions expose their existing shortcut storage here. Execution stays with the extension.
/// Register on the main thread, usually from Services.start(), using a stable, namespaced id.
struct ShortcutRegistration: Identifiable {
    let id: String
    let title: String
    let group: String
    let get: () -> TabHotkey?
    let set: (TabHotkey?) -> Void
}

enum ShortcutRegistry {
    private(set) static var shortcuts: [ShortcutRegistration] = []

    static func register(id: String, title: String, group: String = "Extensions",
                         get: @escaping () -> TabHotkey?, set: @escaping (TabHotkey?) -> Void) {
        shortcuts.removeAll { $0.id == id }
        shortcuts.append(ShortcutRegistration(id: id, title: title, group: group, get: get, set: set))
        shortcuts.sort { ($0.group, $0.title, $0.id) < ($1.group, $1.title, $1.id) }
        NotificationCenter.default.post(name: .nookShortcutsChanged, object: nil)
    }
}

/// Keyed shortcuts ignore the fn flag (macOS adds it to arrows and function keys).
/// Modifier-only dictation gestures retain fn and never collide with keyed shortcuts.
struct ShortcutIdentity: Equatable {
    let keyCode: Int?
    let modifiers: UInt64

    init(_ shortcut: DictationShortcut) {
        keyCode = shortcut.keyCode
        let flags = shortcut.flags.intersection(Modifiers.all)
        modifiers = (shortcut.keyCode == nil ? flags : flags.subtracting(.maskSecondaryFn)).rawValue
    }
}

extension Notification.Name {
    static let nookShortcutsChanged = Notification.Name("nookShortcutsChanged")
}
