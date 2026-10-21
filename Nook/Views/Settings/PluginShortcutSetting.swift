import SwiftUI

/// A generic plugin option rendered with the same native recorder as every other shortcut.
struct PluginShortcutSetting: View {
    let pluginID: String
    let key: String
    let title: String
    @Binding var value: String
    private var item: SettingsShortcutItem {
        let action = key.hasPrefix("shortcut.") ? String(key.dropFirst(9)) : key
        return SettingsShortcutItem(id: "extension:plugin.\(pluginID)/\(action)", title: title, group: "Plugins", get: {
            guard let bytes = value.data(using: .utf8), let shortcut = try? JSONDecoder().decode(TabHotkey.self, from: bytes) else { return nil }
            return DictationShortcut(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers, display: shortcut.display)
        }, set: { shortcut in
            guard let shortcut, let code = shortcut.keyCode,
                  let data = try? JSONEncoder().encode(TabHotkey(keyCode: code, modifiers: shortcut.modifiers, display: shortcut.display)), let text = String(data: data, encoding: .utf8) else { value = ""; return }
            value = text
        })
    }
    var body: some View { LabeledContent(title) { SettingsShortcutRecorder(item: item) } }
}
