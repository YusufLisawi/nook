import AppKit
import Combine

final class WindowShortcuts: ObservableObject {
    static let shared = WindowShortcuts()
    static let storageKey = "windowManagementShortcuts"
    static let almostScaleKey = "windowManagementAlmostScale"
    var failures: [String: String] = [:]
    private var observer: AnyCancellable?

    private init() {
        observer = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }

    func all() -> [String: TabHotkey] {
        guard let data = PluginDefaults.standard.data(forKey: Self.storageKey) else { return [:] }
        return (try? JSONDecoder().decode([String: TabHotkey].self, from: data)) ?? [:]
    }

    func get(_ action: WindowAction) -> TabHotkey? { all()[action.rawValue] }

    func set(_ action: WindowAction, _ hotkey: TabHotkey?) {
        objectWillChange.send()
        var values = all()
        values[action.rawValue] = hotkey
        PluginDefaults.standard.set(try? JSONEncoder().encode(values), forKey: Self.storageKey)
        PluginEvents.emit("windows", NSNull()) // each notch reloads its own captured target
    }

    func action(key: Int64, modifiers: CGEventFlags) -> WindowAction? {
        let values = all()
        guard let action = WindowAction.allCases.first(where: {
            values[$0.rawValue]?.keyCode == Int(key) && values[$0.rawValue]?.modifiers == modifiers.rawValue
        }), let hotkey = values[action.rawValue], conflicts(hotkey, for: action).isEmpty else { return nil }
        return action
    }

    func conflicts(_ hotkey: TabHotkey, for action: WindowAction) -> [String] { failures[action.rawValue].map { [$0] } ?? [] }
}
