import SwiftUI

extension Notification.Name {
    static let nookKeyboardFocus = Notification.Name("nookKeyboardFocus")
}

private struct KeyboardOwnerKey: EnvironmentKey {
    static let defaultValue = ""
}

extension EnvironmentValues {
    var nookKeyboardOwner: String {
        get { self[KeyboardOwnerKey.self] }
        set { self[KeyboardOwnerKey.self] = newValue }
    }
}

/// An explicit entry point for each native tab, independent of the system's Tab-to-buttons preference.
private struct KeyboardInitialFocus: ViewModifier {
    let tab: String
    @Environment(\.nookKeyboardOwner) private var owner
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content.focused($focused)
            .onReceive(NotificationCenter.default.publisher(for: .nookKeyboardFocus)) { note in
                guard note.userInfo?["owner"] as? String == owner, note.userInfo?["tab"] as? String == tab,
                      let window = note.object as? NSWindow, window.isKeyWindow else { return }
                focused = true
            }
    }
}

private struct KeyboardFocusRing: ViewModifier {
    let initialTab: String?
    @Environment(\.nookKeyboardOwner) private var owner
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content.focusable().focused($focused)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.orange.opacity(focused ? 1 : 0), lineWidth: 2).allowsHitTesting(false))
            .onReceive(NotificationCenter.default.publisher(for: .nookKeyboardFocus)) { note in
                guard let initialTab, note.userInfo?["owner"] as? String == owner, note.userInfo?["tab"] as? String == initialTab,
                      let window = note.object as? NSWindow, window.isKeyWindow else { return }
                focused = true
            }
    }
}

extension View {
    func keyboardInitialFocus(tab: String) -> some View { modifier(KeyboardInitialFocus(tab: tab)) }
    func keyboardFocusRing(initialTab: String? = nil) -> some View { modifier(KeyboardFocusRing(initialTab: initialTab)) }
}
