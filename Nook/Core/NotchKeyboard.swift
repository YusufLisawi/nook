import AppKit
import Combine
import SwiftUI

final class NotchKeyboardState: ObservableObject {
    enum Target {
        case tab(String)
        case group(String)
        case command(String)
        case action(KeyboardActions.Action)
    }
    struct Entry: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let symbol: String
        let shortcut: String
        let target: Target
    }

    @Published var isPresented = false
    @Published var query = "" { didSet { selectedIndex = 0 } }
    @Published var selectedIndex = 0
    /// Keyboard visits stay open as the pointer moves away, without changing the user's pin.
    var engaged = false
    weak var vm: NotchViewModel?

    init(vm: NotchViewModel) { self.vm = vm }

    var entries: [Entry] {
        guard let vm else { return [] }
        let dock = vm.dockItems
        var entries = vm.enabledTabs.map { tab in
            let index = dock.firstIndex { $0.id == tab.id }
            let group = TabNavigationStore.shared.group(containing: tab.id)
            return Entry(id: "tab:\(tab.id)", title: tab.name, subtitle: group.map { "Tab · \($0.name)" } ?? "Tab",
                         symbol: tab.symbol,
                         shortcut: index.flatMap { $0 < 9 ? "⌘\($0 + 1)" : nil } ?? TabHotkeys.get(tab.id)?.display ?? "",
                         target: .tab(tab.id))
        }
        entries += TabNavigationStore.shared.groups.filter { group in group.members.contains(where: vm.isEnabled) }.map { group in
            let index = dock.firstIndex { $0.id == group.id }
            return Entry(id: group.id, title: group.name, subtitle: "Tab Group", symbol: group.symbol,
                         shortcut: index.flatMap { $0 < 9 ? "⌘\($0 + 1)" : nil } ?? group.hotkey?.display ?? "", target: .group(group.id))
        }
        entries += (Features.shared.enabled("commands") ? vm.services.commands.commands : []).filter(\.enabled).map {
            Entry(id: "command:\($0.id)", title: $0.name, subtitle: "AI Command", symbol: "wand.and.stars",
                  shortcut: $0.hotkey?.display ?? "", target: .command($0.id))
        }
        entries += KeyboardActions.shared.actions.filter { action in
            action.ownerID == vm.web.keyboardID && vm.isEnabled(action.pluginID)
        }.map { action in
            let pluginName = vm.enabledTabs.first { $0.id == action.pluginID }?.name ?? action.pluginID
            return Entry(id: "action:\(action.pluginID):\(action.id)", title: action.title,
                         subtitle: action.subtitle.isEmpty ? pluginName : "\(pluginName) · \(action.subtitle)",
                         symbol: "bolt", shortcut: action.shortcut, target: .action(action))
        }
        return entries
    }

    var results: [Entry] {
        entries.enumerated().compactMap { index, entry -> (Entry, Int, Int)? in
            guard let score = KeyboardSearch.score(query, in: entry.title + " " + entry.subtitle) else { return nil }
            return (entry, score, index)
        }.sorted { $0.1 == $1.1 ? $0.2 < $1.2 : $0.1 > $1.1 }.map { $0.0 }
    }

    var selected: Entry? {
        let entries = results
        return entries.isEmpty ? nil : entries[min(selectedIndex, entries.count - 1)]
    }

    func move(_ delta: Int) {
        let count = results.count
        guard count > 0 else { return }
        selectedIndex = (min(selectedIndex, count - 1) + delta + count) % count
    }
}

/// Lives as long as its panel. All local shortcuts are scoped to that panel's events.
final class NotchKeyboardController {
    private weak var panel: NotchPanel?
    private weak var vm: NotchViewModel?
    private weak var previousKeyWindow: NSWindow?
    private var monitor: Any?
    private var tabSubscription: AnyCancellable?
    private var focusSubscription: AnyCancellable?
    private var focusRequest = 0
    private var focusPending = false
    private var bufferedKeys: [NSEvent] = []

    init(panel: NotchPanel, vm: NotchViewModel) {
        self.panel = panel
        self.vm = vm
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel, self.vm?.isOpen == true else { return event }
            if let input = event.cgEvent, NookSyntheticInput.isMouseEvent(input) { return event }
            if self.handle(event) { return nil }
            if self.focusPending {
                self.bufferedKeys.append(event)
                return nil
            }
            return event
        }
        vm.contentDidAttach = { [weak self, weak vm] in
            guard let self, vm?.keyboard.engaged == true else { return }
            if vm?.launcherPresented == true || vm?.keyboard.isPresented == true { self.finishFocus() }
            else { self.focusContent() }
        }
        tabSubscription = vm.$tab.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.vm?.keyboard.engaged == true else { return }
                self.focusContent()
            }
        }
        focusSubscription = NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification, object: panel).sink { [weak vm] _ in
            if vm?.keyboard.engaged == true { vm?.close() }
        }
    }

    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

    func open() {
        guard let vm, let panel else { return }
        if !panel.isKeyWindow {
            previousKeyWindow = NSApp.keyWindow.flatMap { $0 is NotchPanel ? nil : $0 }
        }
        focusPending = true
        vm.keyboard.engaged = true
        vm.open()
        panel.ignoresMouseEvents = false
        panel.makeKeyAndOrderFront(nil)
        focusContent()
    }

    func didClose() {
        focusRequest += 1
        focusPending = false
        bufferedKeys.removeAll()
        vm?.keyboard.isPresented = false
        vm?.keyboard.engaged = false
        if panel?.isKeyWindow == true, let previousKeyWindow, previousKeyWindow.isVisible { previousKeyWindow.makeKey() }
        previousKeyWindow = nil
    }

    func escape() {
        guard let vm else { return }
        if vm.launcherPresented { vm.launcherEscape?() }
        else if vm.keyboard.isPresented { dismissPalette() }
        else if vm.showingSettings { vm.showingSettings = false; focusContent() }
        else { vm.close() }
    }

    private func focusContent(attempt: Int = 0, completion: (() -> Void)? = nil) {
        focusRequest += 1
        if vm?.launcherPresented != true { focusPending = true }
        let request = focusRequest
        // Wait for the newly selected SwiftUI content to attach, without focusing a detached WKWebView.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            guard let self, self.focusRequest == request, let vm = self.vm, let panel = self.panel,
                  vm.isOpen, !vm.launcherPresented, !vm.keyboard.isPresented, panel.isKeyWindow else { return }
            if !vm.showingSettings, let tab = vm.currentTab, let view = vm.web.view(for: tab) {
                if view.window === panel {
                    panel.makeFirstResponder(view)
                    view.evaluateJavaScript("window.nook?.keyboard?.focus()") { [weak self] _, _ in
                        guard let self, self.focusRequest == request else { return }
                        self.finishFocus()
                        completion?()
                    }
                } else if attempt < 5 {
                    self.focusContent(attempt: attempt + 1, completion: completion)
                }
            } else {
                panel.makeFirstResponder(panel.contentView)
                panel.selectNextKeyView(nil)
                if !vm.showingSettings {
                    NotificationCenter.default.post(name: .nookKeyboardFocus, object: panel, userInfo: ["tab": vm.tab, "owner": vm.web.keyboardID])
                }
                // Native FocusState changes in the notification commit on the next update pass.
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.focusRequest == request else { return }
                    self.finishFocus()
                    completion?()
                }
            }
        }
    }

    private func finishFocus() {
        guard let vm, vm.isOpen, panel?.isKeyWindow == true else { return }
        focusPending = false
        let keys = bufferedKeys
        bufferedKeys.removeAll()
        for event in keys where vm.isOpen { NSApp.sendEvent(event) }
    }

    private func dismissPalette() {
        vm?.keyboard.isPresented = false
        focusContent()
    }

    func run(_ entry: NotchKeyboardState.Entry, alternate: Bool) {
        guard let vm else { return }
        vm.keyboard.isPresented = false
        switch entry.target {
        case let .tab(id):
            vm.select(id)
            vm.showingSettings = alternate
            focusContent()
        case let .group(id):
            if alternate {
                TabNavigationStore.shared.settingsSelection = id
                (NSApp.delegate as? AppDelegate)?.showSettings(pane: "tabs")
            } else if let group = TabNavigationStore.shared.group(id) {
                let members = group.members.filter(vm.isEnabled)
                if let member = members.contains(group.lastMember ?? "") ? group.lastMember : members.first { vm.select(member) }
                focusContent()
            }
        case let .command(id):
            if alternate {
                vm.close()
                (NSApp.delegate as? AppDelegate)?.showSettings(pane: "commands")
            } else { vm.services.commands.run(id, fromNotch: true) }
        case let .action(action):
            vm.select(action.pluginID)
            // Let the tab subscription schedule first; then deliver after focus, so an
            // action such as "New note" can put the caret in its own editor.
            DispatchQueue.main.async { [weak self, weak vm] in
                self?.focusContent {
                    vm?.web.emit(alternate ? "actionAlternate" : "action", action.id, to: action.pluginID)
                }
            }
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard let vm else { return false }
        vm.keyboard.engaged = true
        if vm.launcherPresented { return vm.launcherKeyHandler?(event) ?? false }
        if vm.tab == "files", vm.currentTab?.isWeb == false, !vm.keyboard.isPresented,
           FileSearchTabState.handle(event, owner: vm.web.keyboardID) { return true }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if event.keyCode == 53 { escape(); return true }
        if Features.shared.enabled("keyboard"), flags == .command, key == "k" {
            if vm.keyboard.isPresented { dismissPalette() }
            else {
                vm.showingSettings = false
                vm.keyboard.query = ""
                focusRequest += 1
                focusPending = true
                vm.keyboard.isPresented = true
            }
            return true
        }
        if vm.keyboard.isPresented {
            switch event.keyCode {
            case 125: vm.keyboard.move(1); return true
            case 126: vm.keyboard.move(-1); return true
            case 36, 76:
                if let entry = vm.keyboard.selected { run(entry, alternate: flags.contains(.command)) }
                return true
            default: break
            }
        }
        if flags == .command, let number = Int(key), (1...9).contains(number) {
            if let item = DockLayout.numbered(number, in: vm.dockItems) {
                vm.keyboard.isPresented = false
                vm.selectDockItem(item)
                focusContent()
            }
            return true
        }
        if flags == [.command, .option], event.keyCode == 123 || event.keyCode == 124 {
            vm.keyboard.isPresented = false
            vm.stepDeck(event.keyCode == 123 ? -1 : 1)
            focusContent()
            return true
        }
        if (event.keyCode == 48 && (flags == .control || flags == [.control, .shift])) ||
            (flags == .command && (key == "[" || key == "]")) {
            vm.keyboard.isPresented = false
            vm.step(flags.contains(.shift) || key == "[" ? -1 : 1)
            focusContent()
            return true
        }
        if !vm.keyboard.isPresented, let action = KeyboardActions.shared.actions.first(where: {
            $0.ownerID == vm.web.keyboardID && $0.pluginID == vm.tab && KeyboardActions.matches($0.shortcut, event: event)
        }) {
            if !event.isARepeat { vm.web.emit("action", action.id, to: action.pluginID) }
            return true
        }
        if !vm.keyboard.isPresented {
            let modifiers = CGEventFlags(rawValue: UInt64(flags.rawValue))
            if Features.shared.enabled("commands"), let command = vm.services.commands.commands.first(where: {
                $0.enabled && $0.hotkey?.keyCode == Int(event.keyCode) && $0.hotkey?.modifiers == modifiers.rawValue
            }) {
                if !event.isARepeat { vm.services.commands.run(command.id, fromNotch: true) }
                return true
            }
            if Features.shared.enabled("windows"), WindowShortcuts.shared.action(key: Int64(event.keyCode), modifiers: modifiers) != nil {
                if !event.isARepeat { _ = WindowManager.shared.handleShortcut(key: Int64(event.keyCode), modifiers: modifiers, from: vm) }
                return true
            }
            if let group = NativeShortcutIntegration.group(key: Int64(event.keyCode), modifiers: modifiers) {
                if !event.isARepeat { vm.toggleGroup(group.id); if vm.isOpen { focusContent() } }
                return true
            }
            if let tab = TabHotkeys.tab(forKey: Int64(event.keyCode), modifiers: modifiers) {
                if !event.isARepeat {
                    if vm.isOpen && vm.tab == tab { vm.close() }
                    else { vm.open(tab: tab); focusContent() }
                }
                return true
            }
        }
        return false
    }
}
