import AppKit
import SwiftUI
import UserNotifications
import WebKit

/// Creates one WKWebView per web plugin for a notch and answers its `window.nook` calls.
final class WebPluginHost: NSObject {
    let keyboardID = UUID().uuidString
    weak var vm: NotchViewModel?
    private var views: [String: WKWebView] = [:]
    private var work: [String: PluginWork] = [:]
    private var revision = 0
    private var observers: [NSObjectProtocol] = []
    private var evictions: [String: DispatchWorkItem] = [:]

    deinit {
        FeatureVisibility.set(owner: keyboardID, plugin: nil)
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        evictions.values.forEach { $0.cancel() }
        work.values.forEach { $0.cancel() }
        for view in views.values { view.stopLoading(); view.configuration.userContentController.removeScriptMessageHandler(forName: "nook") }
        PluginEngine.shared.removeOwner(keyboardID)
        views.keys.forEach { PluginEngine.shared.releasePage($0) }
        KeyboardActions.shared.remove(ownerID: keyboardID)
    }

    init(vm: NotchViewModel) {
        self.vm = vm
        super.init()
        PluginHostAPI.shared.register(vm)
        observers.append(NotificationCenter.default.addObserver(forName: .nookPluginEvent, object: nil, queue: .main) { [weak self] note in
            guard let event = note.userInfo?["event"] as? String else { return }
            self?.emit(event, note.userInfo?["payload"] ?? NSNull(), to: note.userInfo?["plugin"] as? String)
        })
        observers.append(NotificationCenter.default.addObserver(forName: .nookFeaturesChanged, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            for id in Array(self.views.keys) where !Features.shared.tabEnabled(id) { self.unload(id) }
            for view in self.views.values {
                view.evaluateJavaScript(BridgeRegistry.javascript + "\n" + PluginEngine.javascript)
            }
        })
    }

    private func unload(_ id: String) {
        PluginEngine.shared.releasePage(id)
        evictions.removeValue(forKey: id)?.cancel()
        work.removeValue(forKey: id)?.cancel()
        guard let view = views.removeValue(forKey: id) else { return }
        view.stopLoading(); view.configuration.userContentController.removeScriptMessageHandler(forName: "nook")
        view.removeFromSuperview()
        KeyboardActions.shared.remove(ownerID: keyboardID, pluginID: id)
    }
    func visibilityChanged() {
        PluginEngine.shared.setVisible(owner: keyboardID, plugin: vm?.isOpen == true && vm?.launcherPresented == false ? vm?.tab : nil)
        FeatureVisibility.set(owner: keyboardID, plugin: vm?.isOpen == true && vm?.launcherPresented == false ? vm?.tab : nil)
        for id in Array(views.keys) {
            let visible = vm?.isOpen == true && vm?.tab == id && vm?.launcherPresented == false
            if visible { evictions.removeValue(forKey: id)?.cancel() }
            else if evictions[id] == nil {
                let work = DispatchWorkItem { [weak self] in self?.unload(id) }
                evictions[id] = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: work)
            }
            views[id]?.evaluateJavaScript("window.nook && nook._emit('visibility', \(visible ? "true" : "false"))")
        }
    }

    func view(for tab: TabItem) -> WKWebView? {
        guard Features.shared.tabEnabled(tab.id), case let .web(dir, entry) = tab.kind else { return nil }
        let current = Services.shared.plugins.revision
        if current != revision {
            revision = current
            KeyboardActions.shared.remove(ownerID: keyboardID)
            for (id, view) in views {
                guard let tab = Services.shared.plugins.tabs.first(where: { $0.id == id }), case let .web(dir, entry) = tab.kind else { continue }
                injectScripts(view.configuration.userContentController, tab: tab, dir: dir)
                view.loadFileURL(dir.appendingPathComponent(entry), allowingReadAccessTo: dir)
            } // Refresh SDK/entry too, including a v1 → v2 Store update, without discarding web views.
        }
        if let view = views[tab.id] { return view }
        work[tab.id] = PluginWork()
        let view = makeView(tab: tab, dir: dir, entry: entry)
        views[tab.id] = view
        visibilityChanged()
        return view
    }

    func emit(_ event: String, _ payload: Any, to pluginID: String? = nil) {
        guard let data = try? JSONSerialization.data(withJSONObject: ["e": event, "d": payload], options: [.fragmentsAllowed]),
              let json = String(data: data, encoding: .utf8) else { return }
        for (id, view) in views where pluginID == nil || pluginID == id {
            view.evaluateJavaScript("(function(m){window.nook && nook._emit(m.e, m.d)})(\(json))")
        }
    }

    private func makeView(tab: TabItem, dir: URL, entry: String) -> WKWebView {
        let config = WKWebViewConfiguration()
        let content = config.userContentController
        content.addScriptMessageHandler(BridgeHandler(host: self, pluginID: tab.id), contentWorld: .page, name: "nook")
        injectScripts(content, tab: tab, dir: dir)
        let view = DropWebView(frame: .zero, configuration: config)
        view.onFiles = { [weak self] event, payload in self?.emit(event, payload, to: tab.id) }
        view.setValue(false, forKey: "drawsBackground")
        view.underPageBackgroundColor = .clear
        view.isInspectable = true
        view.loadFileURL(dir.appendingPathComponent(entry), allowingReadAccessTo: dir)
        return view
    }

    private func injectScripts(_ content: WKUserContentController, tab: TabItem, dir: URL) {
        let pluginInfo: [String: Any] = ["id": tab.id, "name": tab.name, "apiVersion": (try? PluginManifestV2(directory: dir).apiVersion) ?? 1]
        let info = (try? JSONSerialization.data(withJSONObject: pluginInfo)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        content.removeAllUserScripts()
        content.addUserScript(WKUserScript(source: Self.bridgeJS(pluginInfo: info) + "\n" + BridgeRegistry.javascript + "\n" + KeyboardWebSupport.script + "\n" + PluginEngine.javascript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    }

    // MARK: Bridge

    fileprivate func handle(pluginID: String, fn: String, args: [Any], reply: @escaping (Any?, String?) -> Void) {
        guard Features.shared.tabEnabled(pluginID) else { return reply(nil, "This plugin is turned off in Settings → Features.") }
        guard let directory = Services.shared.plugins.tabs.first(where: { $0.id == pluginID })?.dir else { return reply(nil, "Plugin is no longer installed.") }
        if PluginEngine.shared.intercept(id: pluginID, directory: directory, method: fn, args: args, vm: vm, reply: reply) { return }
        guard Features.shared.tabEnabled(pluginID), Features.shared.allowsBridge(fn) else { reply(nil, "This feature is turned off in Settings → Features."); return }
        if fn == "system", vm?.isOpen != true || vm?.tab != pluginID { reply(nil, "System stats are sampled only while visible."); return }
        let s = Services.shared
        let arg = { (i: Int) -> Any? in i < args.count && !(args[i] is NSNull) ? args[i] : nil }
        let str = { (i: Int) -> String in arg(i) as? String ?? "" }
        let ok = { reply(NSNull(), nil) }

        switch fn {
        case "storage.get": reply(PluginStorage(pluginID).get(str(0)) ?? NSNull(), nil)
        case "storage.set": PluginStorage(pluginID).set(str(0), arg(1)); ok()
        case "storage.all": reply(PluginStorage(pluginID).all(), nil)
        case "settings.get":
            let tab = s.plugins.tabs.first { $0.id == pluginID }
            reply(tab.map { PluginSettingsStore.values(for: $0).mapValues(\.any) } ?? [:], nil)
        case "settings.set":
            if let tab = s.plugins.tabs.first(where: { $0.id == pluginID }) { PluginSettingsStore.set(tab, str(0), JSONValue(any: arg(1))) }
            ok()
        case "settings.open": vm?.showingSettings = true; ok()
        case "shell":
            let timeout = (arg(1) as? [String: Any])?["timeout"] as? Double ?? 15
            Shell.run(str(0), timeout: timeout, work: work[pluginID]) { reply($0, nil) }
        case "fetch": HTTP.fetch(str(0), options: arg(1) as? [String: Any] ?? [:], work: work[pluginID]) { result, error in reply(result, error) }
        case "system": reply(s.system.snapshot(), nil)
        case "clipboard.write":
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(str(0), forType: .string)
            ok()
        case "clipboard.read": reply(NSPasteboard.general.string(forType: .string) ?? "", nil)
        case "open":
            let target = str(0)
            let url = target.hasPrefix("/") || target.hasPrefix("~")
                ? URL(fileURLWithPath: (target as NSString).expandingTildeInPath) : URL(string: target)
            if let url { NSWorkspace.shared.open(url) }
            ok()
        case "notify": Notifier.post(title: str(0), body: str(1)); ok()
        case "log": PluginLog.write(pluginID, level: str(0), message: str(1)); ok()
        case "activity.set":
            let a = arg(0) as? [String: Any] ?? [:]
            s.pluginActivity = PluginActivity(pluginID: pluginID, text: a["text"] as? String ?? "",
                                              symbol: a["symbol"] as? String ?? "sparkle", color: a["color"] as? String ?? "#ffffff")
            ok()
        case "activity.clear":
            if s.pluginActivity?.pluginID == pluginID { s.pluginActivity = nil }
            ok()
        case "notch.close": vm?.close(); ok()
        case "notch.pin": vm?.pinned = arg(0) as? Bool ?? false; ok()
        case "notch.togglePin": vm?.pinned.toggle(); ok()
        case "notch.setHeight":
            if let h = arg(0) as? Double { withAnimation(NotchViewModel.spring) { vm?.heightOverrides[pluginID] = CGFloat(h) } }
            ok()
        case "timer.start":
            s.timers.set(minutes: max(1, arg(0) as? Int ?? 25))
            s.timers.start()
            reply(timerState(s.timers), nil)
        case "timer.stop": s.timers.reset(); reply(timerState(s.timers), nil)
        case "timer.state": reply(timerState(s.timers), nil)
        case let f where f.hasPrefix("proxy."): s.proxy.handle(String(f.dropFirst(6)), args: args, reply: reply)
        case "ai.chat":
            AIChat.send(messages: arg(0) as? [[String: Any]] ?? [], options: arg(1) as? [String: Any] ?? [:], work: work[pluginID], reply: reply)
        case let f where f.hasPrefix("commands."): s.commands.handle(String(f.dropFirst(9)), args: args, reply: reply)
        case let f where f.hasPrefix("audio."): s.audio.handle(String(f.dropFirst(6)), args: args, reply: reply)
        case let f where f.hasPrefix("dictation."): s.dictation.handle(String(f.dropFirst(10)), args: args, reply: reply)
        default:
            let scopedArgs: [Any] = fn == "actions.register" ? Array(args.prefix(1)) + [keyboardID] : args
            if !BridgeRegistry.handle(fn, args: scopedArgs, pluginID: pluginID, reply: reply) { reply(nil, "Unknown nook call: \(fn)") }
        }
    }

    private func timerState(_ t: TimerService) -> [String: Any] {
        ["running": t.isRunning, "mode": t.mode == .countdown ? "timer" : (t.mode == .pomodoro ? "pomodoro" : "stopwatch"), "remaining": t.value, "text": t.displayText]
    }

    /// Nook UI kit (nk-* classes), as a JS string literal.
    private static let uiKit: String = {
        let css = Bundle.main.url(forResource: "nook-ui", withExtension: "css", subdirectory: "NookUI").flatMap { try? String(contentsOf: $0) } ?? ""
        let data = (try? JSONSerialization.data(withJSONObject: [css])) ?? Data("[\"\"]".utf8)
        return String(decoding: data, as: UTF8.self) + "[0]"
    }()

    private static func bridgeJS(pluginInfo: String) -> String {
        """
        (() => {
          const KIT = \(uiKit);
          const call = (fn, ...args) => window.webkit.messageHandlers.nook.postMessage({ fn, args });
          // Forward console + uncaught errors to ~/Library/Logs/Nook/plugins.log (`nook logs`).
          ['log', 'info', 'warn', 'error'].forEach(level => {
            const original = console[level].bind(console);
            console[level] = (...a) => { original(...a); try { call('log', level, a.map(x => typeof x === 'string' ? x : JSON.stringify(x)).join(' ')); } catch {} };
          });
          window.addEventListener('error', e => call('log', 'error', `${e.message} (${(e.filename || '').split('/').pop()}:${e.lineno})`));
          window.addEventListener('unhandledrejection', e => call('log', 'error', 'Unhandled promise: ' + (e.reason && e.reason.message || e.reason)));
          const listeners = {};
          window.nook = {
            plugin: \(pluginInfo),
            settings: { get: () => call('settings.get'), set: (k, v) => call('settings.set', k, v), open: () => call('settings.open') },
            storage: { get: k => call('storage.get', k), set: (k, v) => call('storage.set', k, v === undefined ? null : v), all: () => call('storage.all') },
            shell: (c, o) => call('shell', c, o || {}),
            fetch: (u, o) => call('fetch', u, o || {}),
            system: () => call('system'),
            clipboard: { write: t => call('clipboard.write', String(t)), read: () => call('clipboard.read') },
            open: u => call('open', u),
            notify: (t, b) => call('notify', t, b || ''),
            activity: { set: a => call('activity.set', a || {}), clear: () => call('activity.clear') },
            notch: { close: () => call('notch.close'), pin: p => call('notch.pin', !!p), setHeight: h => call('notch.setHeight', Number(h)) },
            proxy: Object.fromEntries(['list','add','remove','rename','connect','disconnect','ip'].map(n => [n, (...a) => call('proxy.' + n, ...a)])),
            timer: { start: m => call('timer.start', Number(m)), stop: () => call('timer.stop'), state: () => call('timer.state') },
            ai: { chat: (messages, o) => call('ai.chat', messages, o || {}) },
            commands: Object.fromEntries(['list','save','remove','run','recordHotkey','clearHotkey','models','lastRun'].map(n => [n, (...a) => call('commands.' + n, ...a)])),
            audio: Object.fromEntries(['state','setDefault','setDeviceVolume','setDeviceMute','setPreferred','setAppVolume','setAppMute','resetApp','openPrivacy'].map(n => [n, (...a) => call('audio.' + n, ...a)])),
            dictation: Object.fromEntries(['history','retry','remove','copy','paste','clear','state','toggle'].map(n => [n, (...a) => call('dictation.' + n, ...a)])),
            on: (e, cb) => { (listeners[e] = listeners[e] || []).push(cb); },
            _emit: (e, d) => (listeners[e] || []).forEach(cb => { try { cb(d); } catch (err) { console.error(err); } }),
          };
          const css = `:root{--fg:#fff;--muted:rgba(255,255,255,.55);--card:rgba(255,255,255,.06);--card-hover:rgba(255,255,255,.1);--border:rgba(255,255,255,.08);--accent:#ff9f0a;--good:#30d158;--bad:#ff453a;--radius:14px;color-scheme:dark}
            html,body{background:transparent!important;color:var(--fg);font-family:-apple-system,BlinkMacSystemFont,sans-serif;margin:0;-webkit-user-select:none;overflow:hidden}
            input,textarea,[contenteditable]{-webkit-user-select:text}`;
          const style = document.createElement('style'); style.textContent = css + KIT;
          document.documentElement.appendChild(style);
        })();
        """
    }
}

/// Weak wrapper so WKUserContentController doesn't retain the host.
private final class BridgeHandler: NSObject, WKScriptMessageHandlerWithReply {
    weak var host: WebPluginHost?
    let pluginID: String

    init(host: WebPluginHost, pluginID: String) {
        self.host = host
        self.pluginID = pluginID
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard let body = message.body as? [String: Any], let fn = body["fn"] as? String else { return replyHandler(nil, "Bad call") }
        let reply: (Any?, String?) -> Void = { value, error in DispatchQueue.main.async { replyHandler(value, error) } }
        host?.handle(pluginID: pluginID, fn: fn, args: body["args"] as? [Any] ?? [], reply: reply)
    }
}

/// Hands dropped files to the plugin as real paths instead of letting WebKit open them:
/// `nook.on('dragenter')`, `nook.on('dragleave')`, `nook.on('drop', paths)`. Other drags (text, links) go to WebKit.
final class DropWebView: WKWebView {
    var onFiles: ((String, Any) -> Void)?
    private var fileDrag = false

    /// The notch panel isn't key until clicked; without this the first click only focuses it.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func paths(_ info: NSDraggingInfo) -> [String] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return (urls ?? []).map(\.path)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileDrag = !paths(sender).isEmpty
        guard fileDrag else { return super.draggingEntered(sender) }
        onFiles?("dragenter", NSNull())
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileDrag ? .copy : super.draggingUpdated(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        guard fileDrag else { return super.draggingExited(sender) }
        fileDrag = false
        onFiles?("dragleave", NSNull())
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        fileDrag || super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard fileDrag else { return super.performDragOperation(sender) }
        onFiles?("drop", paths(sender))
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        if fileDrag { fileDrag = false } else { super.concludeDragOperation(sender) }
    }
}

struct WebPluginView: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> NSView { attach(to: NSView()) }
    func updateNSView(_ container: NSView, context: Context) { _ = attach(to: container) }

    private func attach(to container: NSView) -> NSView {
        if webView.superview !== container {
            container.subviews.forEach { $0.removeFromSuperview() }
            webView.removeFromSuperview()
            container.addSubview(webView)
        }
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        return container
    }
}

// MARK: Bridge helpers

struct PluginStorage {
    private let url: URL

    init(_ pluginID: String) {
        let dir = Services.supportDir.appendingPathComponent("Data", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("\(pluginID).json")
    }

    func all() -> [String: Any] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    func get(_ key: String) -> Any? { all()[key] }

    func set(_ key: String, _ value: Any?) {
        var dict = all()
        dict[key] = value
        if let data = try? JSONSerialization.data(withJSONObject: dict) { try? data.write(to: url, options: .atomic) }
    }
}

enum Shell {
    static func run(_ command: String, timeout: Double, work: PluginWork? = nil, completion: @escaping ([String: Any]) -> Void) {
        let scope = work ?? PluginWork(), id = UUID(), process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out; process.standardError = err
        scope.add(id) { if process.isRunning { AgentProcess.terminateTree(process.processIdentifier) } }
        DispatchQueue.global(qos: .userInitiated).async {
            defer {
                scope.remove(id)
                try? out.fileHandleForReading.close(); try? err.fileHandleForReading.close()
            }
            do { try scope.perform { try process.run() } } catch {
                return completion(["code": -1, "stdout": "", "stderr": error.localizedDescription])
            }
            let killer = DispatchSource.makeTimerSource(queue: .global())
            killer.schedule(deadline: .now() + max(0.1, timeout))
            killer.setEventHandler { if process.isRunning { AgentProcess.terminateTree(process.processIdentifier) } }
            killer.resume()
            defer { killer.cancel() }
            // Drain both pipes concurrently; a full stderr pipe must not prevent cancellation/exit.
            let errors = ShellErrors(), group = DispatchGroup()
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                errors.data = err.fileHandleForReading.readDataToEndOfFile(); group.leave()
            }
            let stdout = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit(); group.wait()
            completion(["code": Int(process.terminationStatus), "stdout": String(decoding: stdout, as: UTF8.self),
                        "stderr": String(decoding: errors.data, as: UTF8.self)])
        }
    }
}

/// One writer, read only after DispatchGroup.wait establishes completion.
private final class ShellErrors: @unchecked Sendable { var data = Data() }

enum HTTP {
    static func fetch(_ urlString: String, options: [String: Any], work: PluginWork? = nil, completion: @escaping ([String: Any]?, String?) -> Void) {
        guard let url = URL(string: urlString) else { return completion(nil, "Bad URL") }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = options["method"] as? String ?? "GET"
        (options["headers"] as? [String: String])?.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        if let body = options["body"] as? String { request.httpBody = Data(body.utf8) }
        let scope = work ?? PluginWork(), id = UUID(), session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: request) { data, response, error in
            defer { scope.remove(id); session.finishTasksAndInvalidate() }
            if let error { return completion(nil, error.localizedDescription) }
            let http = response as? HTTPURLResponse
            let headers = (http?.allHeaderFields as? [String: String]) ?? [:]
            completion(["status": http?.statusCode ?? 0, "headers": headers, "body": String(decoding: data ?? Data(), as: UTF8.self)], nil)
        }
        if scope.add(id, cancel: { task.cancel(); session.invalidateAndCancel() }) { task.resume() }
    }
}

enum Notifier {
    static func post(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}

/// Plugin console output → ~/Library/Logs/Nook/plugins.log (read it with `nook logs`).
enum PluginLog {
    static let url: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/Nook", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("plugins.log")
    }()
    private static let queue = DispatchQueue(label: "nook.pluginlog")
    private static let formatter = ISO8601DateFormatter()

    static func write(_ pluginID: String, level: String, message: String) {
        let line = "\(formatter.string(from: Date())) [\(pluginID)] \(level.uppercased()) \(message.prefix(2000))\n"
        queue.async {
            if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size > 2_000_000 {
                try? FileManager.default.removeItem(at: url) // keep it small
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}

/// `nook.ai.chat(messages, {json, model, temperature})` → assistant text, via the user's Groq key (same as dictation).
enum AIChat {
    static let defaultModel = "openai/gpt-oss-120b"

    static func send(messages: [[String: Any]], options: [String: Any], work: PluginWork? = nil, reply: @escaping (Any?, String?) -> Void) {
        guard let key = Secrets.get(DictationService.Keys.groqSecret) else {
            return reply(nil, "Add a Groq API key in Nook Settings → Dictation")
        }
        guard !messages.isEmpty else { return reply(nil, "No messages") }
        var body: [String: Any] = [
            "model": options["model"] as? String ?? defaultModel,
            "messages": messages,
            "temperature": options["temperature"] as? Double ?? 0.2,
        ]
        if (body["model"] as? String)?.hasPrefix("openai/gpt-oss") == true { body["reasoning_effort"] = "low" }
        if options["json"] as? Bool == true { body["response_format"] = ["type": "json_object"] }
        var request = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/chat/completions")!, timeoutInterval: 90)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let scope = work ?? PluginWork(), id = UUID()
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { scope.remove(id) }
            if let error { return reply(nil, error.localizedDescription) }
            let json = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any] ?? [:]
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                return reply(nil, (json["error"] as? [String: Any])?["message"] as? String ?? "AI request failed")
            }
            let text = ((json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String ?? ""
            reply(text, nil)
        }
        if scope.add(id, cancel: { task.cancel() }) { task.resume() }
    }
}
