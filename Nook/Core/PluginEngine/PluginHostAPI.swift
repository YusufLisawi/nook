import AppKit
import Security

final class PluginHostAPI {
    static let shared = PluginHostAPI()
    private final class WeakModel { weak var value: NotchViewModel?; init(_ value: NotchViewModel) { self.value = value } }
    private var models: [WeakModel] = []
    private var requests: [String: PluginWork] = [:]
    private var clipboardTimers: [String: Timer] = [:]
    private var shells: [String: [UUID: PluginShellCommand]] = [:]
    private var aiTasks: [String: [UUID: Task<Void, Never>]] = [:]
    private var selectionTargets: [String: AICommandContext] = [:]
    private var selectionContexts: [ObjectIdentifier: AICommandContext] = [:]
    private let filesQueue = DispatchQueue(label: "nook.plugin.files", qos: .utility)

    func register(_ vm: NotchViewModel) { models.removeAll { $0.value == nil }; models.append(WeakModel(vm)) }
    func captureBeforeOpen(_ vm: NotchViewModel) {
        let approved = PluginEngine.shared.manifests.values.filter { $0.requested.contains("accessibility") && PluginPermissions.shared.approved($0) && Features.shared.tabEnabled($0.id) }
        guard !approved.isEmpty else { return }
        if selectionContexts.count >= 16 { selectionContexts.removeAll() }
        selectionContexts[ObjectIdentifier(vm)] = AICommandContext.capture()
        let windowConsumers = approved.filter { $0.requested.contains("windows") }
        guard !windowConsumers.isEmpty else { return }
        // Opaque process/window identity only. AX manipulation and Space policy belong to helpers.
        var snapshot: [String: Any] = ["context": String(describing: ObjectIdentifier(vm))]
        if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            snapshot["pid"] = app.processIdentifier
            if AXIsProcessTrusted() {
                let ax = AXUIElementCreateApplication(app.processIdentifier)
                AXUIElementSetMessagingTimeout(ax, 0.015)
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(ax, kAXFocusedWindowAttribute as CFString, &value) == .success,
                   let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
                    let window = unsafeBitCast(value, to: AXUIElement.self)
                    AXUIElementSetMessagingTimeout(window, 0.015)
                    snapshot["windowNumber"] = PluginWindowIdentity.number(window)
                }
            }
        }
        for manifest in windowConsumers { PluginEvents.emit("beforeOpen", snapshot, to: manifest.id) }
    }
    private func model(_ vm: NotchViewModel?) -> NotchViewModel? {
        vm ?? models.compactMap(\.value).first { $0.geometry.screen.frame.contains(NSEvent.mouseLocation) } ?? models.compactMap(\.value).first
    }
    var shortcutContext: String? {
        guard let panel = NSApp.keyWindow as? NotchPanel, let screen = panel.screen,
              let vm = models.compactMap(\.value).first(where: { $0.isOpen && $0.geometry.screen.frame == screen.frame }) else { return nil }
        return String(describing: ObjectIdentifier(vm))
    }
    func stop(_ id: String) {
        PluginHotkeyRecorder.shared.stop(id)
        selectionTargets.removeValue(forKey:id)
        PluginActivities.remove(id)
        PluginCaptureAPI.shared.stop(id)
        clipboardTimers.removeValue(forKey: id)?.invalidate()
        requests.removeValue(forKey: id)?.cancel()
        shells.removeValue(forKey: id)?.values.forEach { $0.cancel() }
        aiTasks.removeValue(forKey: id)?.values.forEach { $0.cancel() }
    }

    static func parameters(_ method: String, _ args: [Any]) -> [String: Any] {
        if args.count == 1, let object = args[0] as? [String: Any] { return object }
        let keys: [String]
        switch method {
        case "actions.register": keys = ["items"]
        case "storage.get", "secrets.get", "secrets.remove": keys = ["key"]
        case "storage.set", "settings.set", "secrets.set": keys = ["key", "value"]
        case "clipboard.write": keys = ["text"]
        case "clipboard.watch", "notch.pin": keys = ["enabled"]
        case "notch.setHeight": keys = ["height"]
        case "shell": keys = ["command", "options"]
        case "fetch": keys = ["url", "options"]
        case "notify": keys = ["title", "body"]
        case "open": keys = ["path"]
        case "log": keys = ["level", "message"]
        case "selection.paste": keys = ["text"]
        case "files.read", "files.reveal", "files.open", "files.trash": keys = ["path"]
        case "files.write": keys = ["path", "text"]
        default: keys = ["value"]
        }
        return Dictionary(uniqueKeysWithValues: zip(keys, args).map { ($0.0, $0.1) })
    }

    func call(id: String, method: String, params p: [String: Any], manifest: PluginManifestV2, vm: NotchViewModel?, reply: @escaping PluginHelperProcess.Reply) {
        let str = { (key: String) in p[key] as? String ?? "" }
        let ok = { reply(NSNull(), nil) }
        switch method {
        case "runtime.keepAlive": PluginEngine.shared.keepAlive(id, enabled:p["enabled"] as? Bool ?? false); ok()
        case "microphone.devices", "microphone.start", "microphone.stop", "audioCapture.start", "audioCapture.state", "audioCapture.level", "audioCapture.update", "audioCapture.stop":
            PluginCaptureAPI.shared.call(id,method,p,reply:reply)
        case "selection.capture":
            let value = p["context"] as? String
            if let value, !value.isEmpty, !self.models.compactMap(\.value).contains(where:{ String(describing:ObjectIdentifier($0)) == value && self.selectionContexts[ObjectIdentifier($0)] != nil }) { reply(nil,"The original text target is no longer available."); return }
            let captured = value.flatMap { value in self.models.compactMap(\.value).first { String(describing:ObjectIdentifier($0)) == value } }.flatMap { selectionContexts[ObjectIdentifier($0)] } ?? AICommandContext.capture()
            selectionTargets[id] = captured
            reply(["app":captured.application?.localizedName ?? "","clipboard":captured.clipboard],nil)
        case "settings.chooseDirectory":
            let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
            reply(panel.runModal() == .OK ? panel.url?.path as Any? ?? NSNull() : NSNull(),nil)
        case "hotkeys.record": PluginHotkeyRecorder.shared.record(owner:id,action:p["id"] as? String ?? "",modifierOnly:p["modifierOnly"] as? Bool ?? false,reply:reply)
        case "files.scopes": reply(PluginPermissions.shared.grants[id]?.fileScopes ?? [], nil)
        case "launcher.open": PluginSearch.open(model(vm)); ok()
        case "features.list": reply(Features.shared.payload, nil)
        case "storage.get": reply(PluginStorage(id).get(str("key")) ?? NSNull(), nil)
        case "storage.set": PluginStorage(id).set(str("key"), p["value"]); ok()
        case "storage.all": reply(PluginStorage(id).all(), nil)
        case "settings.get":
            guard let tab = Services.shared.plugins.tabs.first(where: { $0.id == id }) else { return reply(nil, "Plugin missing.") }
            reply(PluginSettingsStore.values(for: tab).mapValues(\.any), nil)
        case "settings.set":
            guard let tab = Services.shared.plugins.tabs.first(where: { $0.id == id }), tab.settings.contains(where: { $0.key == str("key") }) else { return reply(nil, "Unknown setting.") }
            PluginSettingsStore.set(tab, str("key"), JSONValue(any: p["value"])); ok()
        case "settings.open":
            let pane = manifest.contributes["settings"]?.first?["id"] as? String
            (NSApp.delegate as? AppDelegate)?.showSettings(pane:pane.map { "plugin-" + id + "-" + $0 } ?? "tabs"); ok()
        case "notch.open": model(vm)?.open(tab: id); ok()
        case "notch.close": model(vm)?.close(); ok()
        case "notch.pin": model(vm)?.pinned = p["enabled"] as? Bool ?? false; ok()
        case "notch.togglePin": model(vm)?.pinned.toggle(); ok()
        case "notch.setHeight":
            guard let height = p["height"] as? Double, height.isFinite else { return reply(nil, "Expected a finite height.") }
            model(vm)?.heightOverrides[id] = CGFloat(min(400, max(80, height))); ok()
        case "notch.activity", "activity.set":
            PluginActivities.set(PluginActivity(pluginID: id, text: String(str("text").prefix(24)), symbol: str("symbol").isEmpty ? "puzzlepiece.extension" : str("symbol"), color: str("color").isEmpty ? "#ff9f0a" : str("color"), startedAt:(p["startedAt"] as? Double).map { Date(timeIntervalSince1970:$0) }, style: p["style"] as? String),priority:p["priority"] as? Int ?? 0); ok()
        case "activity.clear": PluginActivities.remove(id); ok()
        case "clipboard.read": reply(NSPasteboard.general.string(forType: .string) ?? "", nil)
        case "clipboard.write": NSPasteboard.general.clearContents(); NSPasteboard.general.setString(str("text"), forType: .string); ok()
        case "clipboard.watch":
            clipboardTimers.removeValue(forKey: id)?.invalidate()
            if p["enabled"] as? Bool ?? true {
                var last = NSPasteboard.general.changeCount
                clipboardTimers[id] = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                    let board = NSPasteboard.general
                    guard board.changeCount != last else { return }; last = board.changeCount
                    PluginEvents.emit("clipboard", ["text": board.string(forType: .string) ?? ""], to: id)
                }
            }
            ok()
        case "files.read", "files.write", "files.open", "files.reveal", "files.trash", "open":
            let scopes = PluginPermissions.shared.grants[id]?.fileScopes ?? []
            let dataRoot = PluginEngine.dataDirectory(id)
            let path = str("path")
            filesQueue.async {
                do {
                    let url = try PluginFileScope.resolve(path, dataRoot: dataRoot, scopes: scopes)
                    switch method {
                    case "files.read":
                        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 4_000_000 else { throw PluginEngineError("File exceeds 4 MB.") }
                        let text = try String(contentsOf: url, encoding: .utf8)
                        DispatchQueue.main.async { reply(text, nil) }
                    case "files.write":
                        let text = p["text"] as? String ?? ""
                        guard text.utf8.count <= 4_000_000 else { throw PluginEngineError("File exceeds 4 MB.") }
                        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try text.write(to: url, atomically: true, encoding: .utf8)
                        DispatchQueue.main.async { ok() }
                    case "files.trash": try FileManager.default.trashItem(at: url, resultingItemURL: nil); DispatchQueue.main.async { ok() }
                    default: DispatchQueue.main.async {
                        if method == "files.reveal" { NSWorkspace.shared.activateFileViewerSelecting([url]) } else { NSWorkspace.shared.open(url) }
                        ok()
                    }
                    }
                } catch { DispatchQueue.main.async { reply(nil, error.localizedDescription) } }
            }
        case "fetch", "network.fetch":
            guard let url = URL(string: str("url")), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return reply(nil, "Network fetch requires an HTTP(S) URL.") }
            HTTP.fetch(url.absoluteString, options: p["options"] as? [String: Any] ?? [:], work: requests[id, default: PluginWork()], completion: reply)
        case "network.open":
            guard let url = URL(string: str("url")), ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return reply(nil, "Expected an HTTP(S) or mailto URL.") }
            NSWorkspace.shared.open(url); ok()
        case "shell":
            let timeout = min(120, max(1, (p["options"] as? [String: Any])?["timeout"] as? Double ?? 15))
            guard (shells[id]?.count ?? 0) < 8 else { return reply(nil, "Too many running shell commands.") }
            let token = UUID(), shell = PluginShellCommand()
            shells[id, default: [:]][token] = shell
            let launcher = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("nook-cli")
            shell.run(command: str("command"), timeout: timeout, launcher: launcher) { value in
                DispatchQueue.main.async { self.shells[id]?.removeValue(forKey: token); reply(value, nil) }
            }
        case "notify", "notifications.post": Notifier.post(title: str("title"), body: str("body")); ok()
        case "ai.complete":
            guard (aiTasks[id]?.count ?? 0) < 4 else { return reply(nil, "Too many running AI requests.") }
            let token = UUID()
            aiTasks[id, default: [:]][token] = Task { @MainActor in
                defer { self.aiTasks[id]?.removeValue(forKey: token) }
                do { reply(try await AIBrain.complete(provider: str("provider").isEmpty ? "codex" : str("provider"), model: str("model").isEmpty ? "gpt-6-luna" : str("model"), effort: str("effort").isEmpty ? "medium" : str("effort"), prompt: str("prompt"), onDelta: { text in PluginEvents.emit("aiDelta", ["requestID":p["requestID"] ?? token.uuidString,"text":text],to:id) }), nil) }
                catch { reply(nil, error.localizedDescription) }
            }
        case "selection.get", "selection.paste", "accessibility.perform":
            guard AXIsProcessTrusted() else { return reply(nil, "Allow Nook in System Settings → Privacy & Security → Accessibility.") }
            if method == "selection.get" || method == "selection.paste" {
                let targetModel = model(vm)
                let supplied = p["context"] as? String
                let explicit = supplied.flatMap { value in self.models.compactMap(\.value).first { String(describing:ObjectIdentifier($0)) == value } }.flatMap { selectionContexts[ObjectIdentifier($0)] }
                if let supplied, !supplied.isEmpty, explicit == nil { reply(nil,"The original text target is no longer available."); return }
                let fallback = supplied == nil ? targetModel.flatMap { $0.isOpen ? selectionContexts[ObjectIdentifier($0)] : nil } : nil
                let context = (method == "selection.paste" ? selectionTargets.removeValue(forKey:id) : nil) ?? explicit ?? fallback ?? AICommandContext.capture()
                if method == "selection.get" { selectionTargets[id] = context }
                if method == "selection.get", let selection = context.selection { reply(selection,nil); return }
                targetModel?.close()
                Task { @MainActor in
                    context.application?.activate()
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    guard PluginPermissions.shared.approved(manifest), Features.shared.tabEnabled(id), AXIsProcessTrusted() else { return reply(nil, "Plugin access was revoked.") }
                    guard context.restoreTarget() else { return reply(nil, "The original text target changed or is unavailable. Focus it and reopen Nook.") }
                    if method == "selection.get" { reply(await SelectionGrabber.selectedText(), nil) }
                    else { SelectionGrabber.paste(str("text"), after:p["after"] as? Bool ?? false, keepOnClipboard: p["keepOnClipboard"] as? Bool ?? false); ok() }
                }
            }
            else {
                let actions = ["press": kAXPressAction, "raise": kAXRaiseAction, "increment": kAXIncrementAction, "decrement": kAXDecrementAction, "confirm": kAXConfirmAction, "cancel": kAXCancelAction]
                guard let action = actions[str("action")], let element = Self.focusedElement() else { return reply(nil, "Unsupported action or no focused element.") }
                let status = AXUIElementPerformAction(element, action as CFString)
                status == .success ? ok() : reply(nil, "Accessibility action failed (\(status.rawValue)).")
            }
        case "windows.frontmost":
            let app = NSWorkspace.shared.frontmostApplication
            var info: [String: Any] = ["name": app?.localizedName ?? "", "bundleID": app?.bundleIdentifier ?? "", "pid": app?.processIdentifier ?? 0, "accessibility": AXIsProcessTrusted()]
            if AXIsProcessTrusted(), let app {
                let element = AXUIElementCreateApplication(app.processIdentifier)
                AXUIElementSetMessagingTimeout(element, 0.2)
                var window: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &window) == .success, let window, CFGetTypeID(window) == AXUIElementGetTypeID() {
                    let win = unsafeBitCast(window, to: AXUIElement.self)
                    var title: CFTypeRef?
                    AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &title)
                    info["title"] = title as? String ?? ""
                    var position: CFTypeRef?, size: CFTypeRef?
                    AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &position)
                    AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &size)
                    if let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() {
                        var point = CGPoint.zero, dimensions = CGSize.zero
                        if AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point), AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions) {
                            info["frame"] = ["x": point.x, "y": point.y, "width": dimensions.width, "height": dimensions.height]
                        }
                    }
                }
            }
            reply(info, nil)
        case "secrets.get", "secrets.set", "secrets.remove":
            if PluginDailyMigration.sharedAccount(id,key:str("key")) {
                if method == "secrets.get" { reply(Secrets.get(str("key")) ?? NSNull() as Any,nil) }
                else { Secrets.set(str("key"),method == "secrets.remove" ? nil : str("value")); ok() }
                return
            }
            do { reply(try PluginKeychain.call(id: id, method: method, key: str("key"), value: str("value")), nil) }
            catch { reply(nil, error.localizedDescription) }
        case "actions.register", "hotkeys.register", "hotkeys.replace", "hotkeys.unregister", "launcher.items", "launcher.answers", "jobs.register", "jobs.unregister":
            do { try PluginContributions.shared.call(id: id, method: method, params: p); ok() }
            catch { reply(nil, error.localizedDescription) }
        case "log": PluginLog.write(id, level: str("level"), message: str("message")); ok()
        case "keyboard.focus": model(vm)?.web.emit("focus", [:], to: id); ok()
        default: reply(nil, "Unknown API v2 method: \(method).")
        }
    }

    private static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.2)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value) == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }
}

enum PluginKeychain {
    static func call(id: String, method: String, key: String, value: String) throws -> Any {
        guard !key.isEmpty, key.count <= 200, value.utf8.count <= 16_384 else { throw PluginEngineError("Invalid secret key or value.") }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.yusuf.nook.plugin." + id, kSecAttrAccount as String: key]
        if method == "secrets.get" {
            var lookup = query; lookup[kSecReturnData as String] = true; lookup[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            let status = SecItemCopyMatching(lookup as CFDictionary, &item)
            if status == errSecItemNotFound { return NSNull() }
            guard status == errSecSuccess else { throw PluginEngineError("Keychain read failed (\(status)).") }
            return (item as? Data).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }
        let status: OSStatus
        if method == "secrets.remove" { status = SecItemDelete(query as CFDictionary) }
        else {
            let data = Data(value.utf8)
            let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if update == errSecItemNotFound {
                var insert = query; insert[kSecValueData as String] = data; insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                status = SecItemAdd(insert as CFDictionary, nil)
            } else { status = update }
        }
        guard status == errSecSuccess || (method == "secrets.remove" && status == errSecItemNotFound) else { throw PluginEngineError("Keychain update failed (\(status)).") }
        return NSNull()
    }
}
