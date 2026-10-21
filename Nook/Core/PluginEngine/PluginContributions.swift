import AppKit
import Carbon
import SwiftUI

/// Every resource is keyed by plugin id and is removed on disable/revoke/uninstall.
final class PluginContributions: NSObject {
    static let shared = PluginContributions()
    static let actionOwner = KeyboardActions.extensionOwner
    private var hotkeyDefinitions: [String:[[String:Any]]] = [:]
    private var paletteScopes: [String:[String:[[String:Any]]]] = [:]
    private var installed = Set<String>()
    private var consumers = ""
    private var hotkeys: [String: (EventHotKeyRef, UInt32)] = [:]
    private var hotkeyActions: [UInt32: (String, String)] = [:]
    private var nextHotkey: UInt32 = 1
    private var handler: EventHandlerRef?
    private var menus: [String: NSStatusItem] = [:]
    private var jobs: [String: Timer] = [:]
    private var answers: [String: PluginLauncherAnswerProvider] = [:]
    private var settings: [String: String] = [:]

    override init() {
        super.init()
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var key = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &key) == noErr else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<PluginContributions>.fromOpaque(context).takeUnretainedValue()
            if let (id, action) = owner.hotkeyActions[key.id] { PluginEvents.emit("hotkey", ["id": action, "context": PluginHostAPI.shared.shortcutContext as Any? ?? NSNull()], to: id) }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    func install(_ manifest: PluginManifestV2) {
        guard installed.insert(manifest.id).inserted else { return }
        let id = manifest.id
        PluginSearch.install(manifest)
        for row in manifest.contributes["hotkeys"] ?? [] { attempt(id) { try self.registerHotkey(id, row) } }
        if let rows = manifest.contributes["launcherItems"], !rows.isEmpty { attempt(id) { try self.registerItems(id, rows) } }
        for row in manifest.contributes["backgroundJobs"] ?? [] { attempt(id) { try self.registerJob(id, row) } }
        for row in manifest.contributes["answerProviders"] ?? [] { attempt(id) { try self.registerAnswer(id, row) } }
        for row in manifest.contributes["menuBar"] ?? [] {
            guard let key = row["id"] as? String else { continue }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.image = NSImage(systemSymbolName: row["symbol"] as? String ?? "puzzlepiece.extension", accessibilityDescription: row["title"] as? String ?? manifest.name)
            item.button?.target = self; item.button?.action = #selector(menuClicked(_:)); item.button?.identifier = NSUserInterfaceItemIdentifier(id + "/" + key)
            menus[id + "/" + key] = item
        }
        for row in manifest.contributes["settings"] ?? [] {
            guard let key = row["id"] as? String else { continue }
            let pane = "plugin-" + id + "-" + key
            settings[pane] = id
            SettingsRegistry.register(id: pane, title: row["title"] as? String ?? manifest.name, symbol: "puzzlepiece.extension", tint: .orange, order: 80) {
                if let entry = row["entry"] as? String, let tab = Services.shared.plugins.tabs.first(where:{ $0.id == id }) {
                    PluginSettingsPage(tab:tab,entry:entry)
                } else { PluginContributedSettings(pluginID:id) }
            }
        }
    }
    private func attempt(_ id: String, _ work: () throws -> Void) {
        do { try work() } catch { PluginLog.write(id, level: "error", message: error.localizedDescription) }
    }
    func reconcileConsumers() {
        let current = "\(Features.shared.enabled("launcher")):\(Features.shared.enabled("smartAnswers"))"
        guard current != consumers else { return }
        consumers = current
        // Consumer changes must not unregister a running helper's unrelated hotkeys/jobs/settings.
        for key in Array(answers.keys) {
            answers.removeValue(forKey: key)?.deactivate()
            LauncherAnswers.unregisterIfLoaded("plugin:" + key)
        }
        for id in installed {
            if !Features.shared.enabled("launcher") { paletteScopes[id]?.removeValue(forKey:"launcher") }
            let retained = paletteScopes[id]?.values.flatMap { $0 } ?? []
            KeyboardActions.shared.register(retained,pluginID:id,ownerID:Self.actionOwner) { _,_ in }
            guard let manifest = PluginEngine.shared.manifests[id] else { continue }
            if Features.shared.enabled("launcher"), let rows = manifest.contributes["launcherItems"], !rows.isEmpty { attempt(id) { try self.registerItems(id, rows) } }
            if Features.shared.enabled("smartAnswers") {
                for row in manifest.contributes["answerProviders"] ?? [] { attempt(id) { try self.registerAnswer(id, row) } }
            }
        }
    }
    func reconcile(active: Set<String>) { for id in installed.subtracting(active) { remove(id) } }
    func remove(_ id: String) {
        installed.remove(id)
        paletteScopes.removeValue(forKey:id)
        hotkeyDefinitions.removeValue(forKey:id)
        PluginGestureHotkeys.shared.remove(id)
        PluginSearch.remove(id)
        for key in Array(hotkeys.keys) where key.hasPrefix(id + "/") { unregisterHotkey(key) }
        for key in Array(menus.keys) where key.hasPrefix(id + "/") { if let item = menus.removeValue(forKey: key) { NSStatusBar.system.removeStatusItem(item) } }
        for key in Array(jobs.keys) where key.hasPrefix(id + "/") { jobs.removeValue(forKey: key)?.invalidate() }
        for key in Array(answers.keys) where key.hasPrefix(id + "/") { answers.removeValue(forKey: key)?.deactivate(); LauncherAnswers.unregisterIfLoaded("plugin:" + key) }
        for pane in settings.filter({ $0.value == id }).keys { SettingsRegistry.unregister(pane); settings.removeValue(forKey: pane) }
        KeyboardActions.shared.remove(ownerID: Self.actionOwner, pluginID: id)
    }

    func call(id: String, method: String, params p: [String: Any]) throws {
        switch method {
        case "hotkeys.replace":
            let rows = p["items"] as? [[String:Any]] ?? []
            guard rows.count <= 100 else { throw PluginEngineError("Too many hotkeys.") }
            let previous = hotkeyDefinitions[id] ?? []
            func clear() {
                for key in Array(hotkeys.keys) where key.hasPrefix(id + "/") { unregisterHotkey(key) }
                PluginGestureHotkeys.shared.remove(id)
            }
            func apply(_ rows: [[String:Any]]) throws {
                for row in rows { if row["mode"] != nil { try PluginGestureHotkeys.shared.register(id,row) } else { try registerHotkey(id,row) } }
            }
            clear()
            do { try apply(rows); hotkeyDefinitions[id] = rows }
            catch { clear(); try? apply(previous); throw error }
        case "hotkeys.register":
            if p["mode"] != nil { try PluginGestureHotkeys.shared.register(id,p) } else { try registerHotkey(id,p) }
            var rows = hotkeyDefinitions[id] ?? []; rows.removeAll { $0["id"] as? String == p["id"] as? String }; rows.append(p); hotkeyDefinitions[id] = rows
        case "hotkeys.unregister":
            let action = p["id"] as? String ?? ""
            unregisterHotkey(id + "/" + action); PluginGestureHotkeys.shared.unregister(id,action:action)
            hotkeyDefinitions[id]?.removeAll { $0["id"] as? String == action }
        case "actions.register": try registerPalette(id, group:p["group"] as? String ?? "web", rows:p["items"] as? [[String:Any]] ?? [])
        case "launcher.items": try registerItems(id, p["items"] as? [[String: Any]] ?? [])
        case "launcher.answers": try registerAnswer(id, p)
        case "jobs.register": try registerJob(id, p)
        case "jobs.unregister": jobs.removeValue(forKey: id + "/" + (p["id"] as? String ?? ""))?.invalidate()
        default: throw PluginEngineError("Unknown contribution method.")
        }
    }

    private func registerPalette(_ id: String, group: String, rows: [[String:Any]]) throws {
        guard group.count <= 100, (paletteScopes[id]?.count ?? 0) < 16 || paletteScopes[id]?[group] != nil else { throw PluginEngineError("Too many action groups.") }
        var groups = paletteScopes[id] ?? [:]; groups[group] = rows
        let combined = groups.keys.sorted().flatMap { groups[$0] ?? [] }
        var failure: String?
        KeyboardActions.shared.register(combined,pluginID:id,ownerID:Self.actionOwner) { _,error in failure = error }
        if let failure { throw PluginEngineError(failure) }
        paletteScopes[id] = groups
    }
    private func registerItems(_ id: String, _ rows: [[String: Any]]) throws {
        guard Features.shared.enabled("launcher") else { throw PluginEngineError("Enable the launcher to contribute items.") }
        try registerPalette(id,group:"launcher",rows:rows)
    }
    private func registerHotkey(_ id: String, _ row: [String: Any]) throws {
        guard let key = row["id"] as? String, !key.isEmpty, key.count <= 100,
              let code = row["keyCode"] as? Int, (0...127).contains(code), let modifiers = row["modifiers"] as? UInt64,
              modifiers & (CGEventFlags.maskCommand.rawValue | CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue) != 0 else { throw PluginEngineError("Hotkeys need id, keyCode and CGEventFlags modifiers (Command, Control or Option).") }
        let name = id + "/" + key
        guard hotkeys.count < 100 || hotkeys[name] != nil else { throw PluginEngineError("Too many global plugin shortcuts.") }
        let shortcut = TabHotkey(keyCode: code, modifiers: modifiers, display: row["display"] as? String ?? "Plugin shortcut")
        let conflict = SettingsShortcutItem.all.filter { $0.id != "extension:plugin." + name && $0.get().map { ShortcutIdentity($0) == ShortcutIdentity(DictationShortcut(keyCode: code, modifiers: modifiers, display: "")) } == true }
        guard conflict.isEmpty else { throw PluginEngineError("Shortcut conflicts with \(conflict.map(\.title).joined(separator: ", ")).") }
        if let system = ShortcutRegistry.externalConflicts(shortcut).first { throw PluginEngineError("Shortcut conflicts with \(system).") }
        unregisterHotkey(name)
        var carbon: UInt32 = 0
        let flags = CGEventFlags(rawValue: modifiers)
        if flags.contains(.maskCommand) { carbon |= UInt32(cmdKey) }; if flags.contains(.maskControl) { carbon |= UInt32(controlKey) }
        if flags.contains(.maskAlternate) { carbon |= UInt32(optionKey) }; if flags.contains(.maskShift) { carbon |= UInt32(shiftKey) }
        let number = nextHotkey; nextHotkey &+= 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(code), carbon, EventHotKeyID(signature: 0x4E4F4F4B, id: number), GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { throw PluginEngineError("This global shortcut is already in use (\(status)).") }
        hotkeys[name] = (ref, number); hotkeyActions[number] = (id, key)
        ShortcutRegistry.register(id: "plugin." + name, title: row["title"] as? String ?? key, group: "Plugins", editable: false, get: { shortcut }, set: { _ in })
    }
    private func unregisterHotkey(_ name: String) {
        if let (ref, number) = hotkeys.removeValue(forKey: name) { UnregisterEventHotKey(ref); hotkeyActions.removeValue(forKey: number) }
        ShortcutRegistry.unregister("plugin." + name)
    }
    private func registerJob(_ id: String, _ row: [String: Any]) throws {
        guard let key = row["id"] as? String, !key.isEmpty, let seconds = row["interval"] as? Double, seconds.isFinite, seconds >= 1, seconds <= 86_400 else { throw PluginEngineError("Jobs need an id and interval in seconds (1–86400).") }
        let name = id + "/" + key
        guard jobs.count < 100 || jobs[name] != nil else { throw PluginEngineError("Too many plugin jobs.") }
        jobs.removeValue(forKey: name)?.invalidate()
        jobs[name] = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { _ in PluginEvents.emit("job", ["id": key], to: id) }
    }
    private func registerAnswer(_ id: String, _ row: [String: Any]) throws {
        guard Features.shared.enabled("launcher"), Features.shared.enabled("smartAnswers"), let key = row["id"] as? String, !key.isEmpty,
              let prefix = row["prefix"] as? String, !prefix.isEmpty,
              let method = row["method"] as? String, !method.isEmpty else { throw PluginEngineError("Answer providers need id, prefix, method, and Launcher and Smart Answers enabled.") }
        let name = id + "/" + key
        guard answers.count < 100 || answers[name] != nil else { throw PluginEngineError("Too many answer providers.") }
        let provider = PluginLauncherAnswerProvider(pluginID: id, key: name, prefix: prefix, method: method)
        answers[name]?.deactivate()
        answers[name] = provider; LauncherAnswers.shared.register(provider)
    }
    @objc private func menuClicked(_ sender: NSStatusBarButton) {
        guard let key = sender.identifier?.rawValue, let slash = key.firstIndex(of: "/") else { return }
        PluginEvents.emit("menuBar", ["id": String(key[key.index(after: slash)...])], to: String(key[..<slash]))
    }
    static func handleURL(_ url: URL) {
        let parts = url.pathComponents.dropFirst()
        guard let id = parts.first, let manifest = PluginEngine.shared.manifests[id], PluginPermissions.shared.approved(manifest), Features.shared.tabEnabled(id) else { return }
        let route = parts.dropFirst().first ?? ""
        guard (manifest.contributes["urlHandlers"] ?? []).contains(where: { $0["id"] as? String == route }) else { return }
        PluginEvents.emit("url", ["handler": route, "url": url.absoluteString], to: id)
    }
}

private struct PluginContributedSettings: View {
    let pluginID: String
    @ObservedObject private var plugins = Services.shared.plugins
    var body: some View {
        Form {
            if let tab = plugins.tabs.first(where: { $0.id == pluginID }) {
                PluginSettingsForm(tab: tab, grouped: true)
                PluginPermissionsSection(tab: tab)
            } else { Text("This plugin is no longer installed.").foregroundStyle(.secondary) }
        }.formStyle(.grouped)
    }
}

/// IPC is asynchronous; the native answer loop only reads this bounded cache. No IPC in the 2 ms budget.
final class PluginLauncherAnswerProvider: LauncherAnswerProvider, LauncherAnswerRefining {
    let id: String
    let pluginID: String
    private let prefix: String
    private let method: String
    private let lock = NSLock()
    private var cache: [String: LauncherAnswer] = [:]
    private var inFlight = Set<String>()
    private var active = true
    func deactivate() { lock.lock(); active = false; cache.removeAll(); lock.unlock() }
    init(pluginID: String, key: String, prefix: String, method: String) { self.pluginID = pluginID; id = "plugin:" + key; self.prefix = prefix; self.method = method }
    func answer(for query: String, context: LauncherAnswerContext) -> LauncherAnswer? {
        guard query.hasPrefix(prefix) else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard active else { return nil }
        return cache[query] ?? LauncherAnswer(pluginID: pluginID, section: "Plugin", expression: query, leftBadge: "", result: "Loading…", rightBadge: "", copyValue: "", isAvailable: false)
    }
    func refine(for query: String, context: LauncherAnswerContext, completion: @escaping () -> Void) {
        lock.lock()
        guard active, cache[query] == nil, inFlight.count < 4, inFlight.insert(query).inserted else { lock.unlock(); return }
        lock.unlock()
        DispatchQueue.main.async {
            PluginEngine.shared.webCall(id: self.pluginID, method: "native.call", args: [self.method, ["query": query]], vm: nil) { result, error in
                self.lock.lock()
                defer { self.lock.unlock() }
                self.inFlight.remove(query)
                guard self.active else { return }
                let row = result as? [String: Any] ?? [:]
                let text = String((row["result"] as? String ?? error ?? "No answer").prefix(2000))
                if self.cache.count >= 32 { self.cache.removeAll() }
                self.cache[query] = LauncherAnswer(pluginID: self.pluginID, section: row["section"] as? String ?? "Plugin", expression: query, leftBadge: "", result: text, rightBadge: "", note: error, copyValue: row["copyValue"] as? String ?? text, isAvailable: error == nil && row["result"] != nil)
                DispatchQueue.main.async(execute: completion)
            }
        }
    }
}
