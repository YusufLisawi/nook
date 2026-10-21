#!/usr/bin/env python3
"""Compile Settings' real models with in-memory services; never launch Nook or touch its data."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
sources = [
    "Nook/Core/Extensions.swift",
    "Nook/Core/PluginEngine/PluginManifestV2.swift",
    "Nook/Core/PluginRegistry.swift",
    "Nook/Core/TabHotkeys.swift",
    "Nook/Core/ShortcutRegistry.swift",
    "Nook/Core/TabNavigation.swift",
    "Nook/Core/TabNavigationStore.swift",
    "Nook/Core/ShortcutGesture.swift",
    "Nook/Views/Settings/SettingsNavigation.swift",
    "Nook/Views/Settings/SettingsShortcutRecorder.swift",
]
stubs = r'''
enum PluginGestureHotkeys { static let shared = State(); struct State { var items: [SettingsShortcutItem] { [] } } }

final class Features {
    static let shared = Features()
    func enabled(_ id: String) -> Bool { true }
    func tabEnabled(_ id: String) -> Bool { true }
    func registerPlugins(_ tabs: [TabItem]) {}
}

import AppKit
import SwiftUI

// Shadow UserDefaults only in this executable: all production preference calls stay in memory.
final class UserDefaults {
    static let standard = UserDefaults()
    static let didChangeNotification = Foundation.UserDefaults.didChangeNotification
    var values: [String: Any] = [:]
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func dictionary(forKey key: String) -> [String: Any]? { values[key] as? [String: Any] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }
}
enum Prefs {
    static let hiddenTabs = "hiddenTabs"
    static let tabGroups = "tabGroups"
    static let dockOrder = "dockItemOrder"
}
struct PluginSetting: Decodable, Equatable { let key: String }
final class MockHotkeys { var paused = false }
final class DictationService {
    enum Keys { static let holdShortcut = "hold"; static let toggleShortcut = "toggle" }
    let hotkeys = MockHotkeys()
    func reloadShortcuts() {}
}
final class AICommands: ObservableObject {
    struct Command: Identifiable { let id: String; let name: String; var hotkey: TabHotkey? }
    @Published var commands: [Command] = []
    func setHotkey(_ id: String, _ hotkey: TabHotkey?) {
        if let index = commands.firstIndex(where: { $0.id == id }) { commands[index].hotkey = hotkey }
    }
}
final class Services {
    static let shared = Services()
    static let supportDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let hotkeys = MockHotkeys()
    let dictation = DictationService()
    let commands = AICommands()
    let plugins = PluginRegistry()
}
'''
main = r'''
import AppKit
import SwiftUI

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ description: String) {
    precondition(condition(), description)
    checks += 1
}

// Search covers whitespace, multiple keywords, case, diacritics, misses, and every built-in pane.
check(SettingsSearch.matches("", in: []), "Empty search includes all panes")
check(SettingsSearch.matches("  AUDIO  retention ", in: SettingsPane.dictation.keywords), "Every query word matches")
check(SettingsSearch.matches("cafe", in: ["Café"]), "Search folds diacritics")
check(!SettingsSearch.matches("audio window", in: SettingsPane.dictation.keywords), "Unmatched query word excludes pane")
for pane in SettingsPane.allCases {
    check(SettingsSearch.matches(pane.title, in: [pane.title] + pane.keywords), "Pane title is searchable")
}
check(SettingsSearch.matches("login", in: SettingsPane.general.keywords), "General keywords include launch at login")
check(SettingsSearch.matches("PATH", in: SettingsPane.tools.keywords), "Command Line includes setting keywords")

// Native extension panes keep the old registration signature, keywords, deterministic ordering, and replacement.
SettingsRegistry.register(id: "test.a", title: "First", symbol: "gear", tint: .gray, order: 9) { EmptyView() }
SettingsRegistry.register(id: "test.b", title: "Second", symbol: "gear", tint: .gray, order: 1, keywords: ["snap"]) { EmptyView() }
check(SettingsRegistry.panes.map(\.id) == ["test.b", "test.a"], "Extension panes sort by order")
check(SettingsRegistry.panes[0].keywords == ["snap"], "Extension search keywords survive registration")
SettingsRegistry.register(id: "test.a", title: "Replacement", symbol: "gear", tint: .gray, order: 0) { EmptyView() }
check(SettingsRegistry.panes.count == 2 && SettingsRegistry.panes[0].title == "Replacement", "Re-registering replaces a pane")
check(SettingsRouter.isKnown("test.a"), "Router accepts extension deep links")
check(!SettingsRouter.isKnown("missing"), "Router rejects unknown deep links")
let router = SettingsRouter()
router.pane = "test.a"
check(UserDefaults.standard.string(forKey: SettingsRouter.lastPaneKey) == "test.a", "Selection persists")
check(SettingsRouter().pane == "test.a", "New router restores selection")
router.pane = nil
check(SettingsRouter().pane == "test.a", "Transient deselection does not erase saved pane")

// Reordering uses the same persisted key as the dock and correctly handles multi-row moves.
let registry = Services.shared.plugins
let original = registry.orderedTabs.map(\.id)
registry.move(from: IndexSet(integer: 0), to: original.count)
check(registry.orderedTabs.map(\.id) == Array(original.dropFirst()) + [original[0]], "Drag first row to end")
check(UserDefaults.standard.stringArray(forKey: "tabOrder") == registry.customOrder, "Settings order persists under dock key")
check(PluginRegistry().orderedTabs.map(\.id) == registry.orderedTabs.map(\.id), "Dock order survives registry recreation")
registry.resetOrder()
registry.move(from: IndexSet([0, 2]), to: 4)
check(registry.orderedTabs.map(\.id) == [original[1], original[3], original[0], original[2]] + Array(original.dropFirst(4)), "Multiple selected rows move together")
registry.resetOrder()
check(registry.orderedTabs.map(\.id) == original && registry.customOrder.isEmpty, "Reset restores manifest order")
UserDefaults.standard.set(["missing", original[2]], forKey: "tabOrder")
let partial = PluginRegistry()
check(partial.orderedTabs.map(\.id) == [original[2]] + original.filter { $0 != original[2] }, "Missing plugins do not hide new tabs")

// Hardware identity ignores display strings, ignores fn for keyed shortcuts, and retains modifier-only gestures.
let option = CGEventFlags.maskAlternate.rawValue
let key = DictationShortcut(keyCode: 49, modifiers: option, display: "Option Space")
let fnKey = DictationShortcut(keyCode: 49, modifiers: option | CGEventFlags.maskSecondaryFn.rawValue, display: "Different label")
check(ShortcutIdentity(key) == ShortcutIdentity(fnKey), "Keyed fn normalization")
check(ShortcutIdentity(key) != ShortcutIdentity(.init(keyCode: nil, modifiers: option, display: "Option")), "Modifier-only does not conflict with keyed shortcut")
check(ShortcutIdentity(.init(keyCode: nil, modifiers: CGEventFlags.maskSecondaryFn.rawValue, display: "fn")) != ShortcutIdentity(.init(keyCode: nil, modifiers: 0, display: "")), "Modifier-only fn is retained")

// Generic extension adapters replace migrated feature-specific adapters.
let tab = SettingsShortcutItem.tab(registry.tabs[0])
tab.set(key)
check(TabHotkeys.get(registry.tabs[0].id)?.keyCode == 49, "Tab recorder writes original tab storage")
check(!tab.conflicts(with:key).contains(where:{ $0.id == tab.id }), "Own shortcut does not conflict")
var extensionHotkey: TabHotkey?
ShortcutRegistry.register(id:"plugin.commands/rewrite",title:"Rewrite",get:{ extensionHotkey },set:{ extensionHotkey = $0 })
let ext = SettingsShortcutItem.all.first { $0.id == "extension:plugin.commands/rewrite" }!
ext.set(fnKey)
check(extensionHotkey?.keyCode == 49, "Plugin recorder invokes storage setter")
check(tab.conflicts(with:key).contains(where:{ $0.id == ext.id }), "Plugin conflicts normalize fn")
ext.set(nil)
check(extensionHotkey == nil, "Clearing plugin assignment invokes setter")
DictationShortcut.save("fixture.hold",nil)
check(DictationShortcut.load("fixture.hold",fallback:.defaultHold) == nil, "Modifier gesture off persists")
DictationShortcut.save("fixture.hold",.defaultHold)
check(DictationShortcut.load("fixture.hold",fallback:.defaultHold) == .defaultHold, "Modifier gesture restores")
tab.set(nil)
check(TabHotkeys.get(registry.tabs[0].id) == nil, "Clearing tab updates storage")

// Settings discovery reads only this harness's temporary plugin directory and publishes on the main actor.
let fixture = Services.supportDir.appendingPathComponent("Plugins/settings-fixture", isDirectory: true)
try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
let manifest = fixture.appendingPathComponent("plugin.json")
try Data(#"{"id":"settings-fixture","name":"Fixture","order":5,"height":180}"#.utf8).write(to: manifest)
let beforeReload = registry.revision
let beforeOrder = registry.customOrder
await registry.reloadForSettings()
check(registry.tabs.contains { $0.id == "settings-fixture" && $0.name == "Fixture" }, "Background Settings discovery publishes file plugins")
check(PluginRegistry.nativeTabs.allSatisfy { native in registry.tabs.contains { $0.id == native.id } }, "Background discovery retains native tabs")
check(registry.revision == beforeReload + 1, "Settings reload notifies live web hosts")
check(registry.customOrder == beforeOrder, "Settings reload preserves dock order")
try Data(#"{"id":"settings-fixture","name":"Changed","order":5,"height":180}"#.utf8).write(to: manifest)
registry.reload()
check(registry.tabs.contains { $0.id == "settings-fixture" && $0.name == "Changed" }, "Existing synchronous reload uses the same discovery rules")
print("Passed \(checks) Settings regression checks; all preferences and services were in memory.")
'''
with tempfile.TemporaryDirectory(prefix="nook-settings-tests-") as temp:
    temp = Path(temp)
    (temp / "Stubs.swift").write_text(stubs)
    (temp / "main.swift").write_text(main)
    executable = temp / "settings-tests"
    subprocess.run([
        "xcrun", "swiftc", "-swift-version", "5", "-warnings-as-errors",
        *[str(root / source) for source in sources],
        str(temp / "Stubs.swift"), str(temp / "main.swift"), "-o", str(executable),
    ], check=True)
    subprocess.run([str(executable), str(temp)], check=True)
