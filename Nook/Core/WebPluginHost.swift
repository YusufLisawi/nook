import AppKit
import SwiftUI
import UserNotifications
import WebKit

/// Creates one WKWebView per web plugin for a notch and answers its `window.nook` calls.
final class WebPluginHost: NSObject {
    weak var vm: NotchViewModel?
    private var views: [String: WKWebView] = [:]
    private var revision = 0

    init(vm: NotchViewModel) {
        self.vm = vm
        super.init()
        NotificationCenter.default.addObserver(forName: .nookPluginEvent, object: nil, queue: .main) { [weak self] note in
            guard let event = note.userInfo?["event"] as? String else { return }
            self?.emit(event, note.userInfo?["payload"] ?? NSNull())
        }
    }

    func view(for tab: TabItem) -> WKWebView? {
        guard case let .web(dir, entry) = tab.kind else { return nil }
        let current = Services.shared.plugins.revision
        if current != revision {
            revision = current
            views.values.forEach { $0.reload() } // pick up edited files without losing the view
        }
        if let view = views[tab.id] { return view }
        let view = makeView(tab: tab, dir: dir, entry: entry)
        views[tab.id] = view
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
        let info = (try? JSONSerialization.data(withJSONObject: ["id": tab.id, "name": tab.name])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        content.addUserScript(WKUserScript(source: Self.bridgeJS(pluginInfo: info), injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let view = DropWebView(frame: .zero, configuration: config)
        view.onFiles = { [weak self] event, payload in self?.emit(event, payload, to: tab.id) }
        view.setValue(false, forKey: "drawsBackground")
        view.underPageBackgroundColor = .clear
        view.isInspectable = true
        view.loadFileURL(dir.appendingPathComponent(entry), allowingReadAccessTo: dir)
        return view
    }

    // MARK: Bridge

    fileprivate func handle(pluginID: String, fn: String, args: [Any], reply: @escaping (Any?, String?) -> Void) {
        let s = Services.shared
        let arg = { (i: Int) -> Any? in i < args.count && !(args[i] is NSNull) ? args[i] : nil }
        let str = { (i: Int) -> String in arg(i) as? String ?? "" }
        let ok = { reply(NSNull(), nil) }

        switch fn {
        case "storage.get": reply(PluginStorage(pluginID).get(str(0)) ?? NSNull(), nil)
        case "storage.set": PluginStorage(pluginID).set(str(0), arg(1)); ok()
        case "storage.all": reply(PluginStorage(pluginID).all(), nil)
        case "shell":
            let timeout = (arg(1) as? [String: Any])?["timeout"] as? Double ?? 15
            Shell.run(str(0), timeout: timeout) { reply($0, nil) }
        case "fetch": HTTP.fetch(str(0), options: arg(1) as? [String: Any] ?? [:]) { result, error in reply(result, error) }
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
        case "notch.setHeight":
            if let h = arg(0) as? Double { withAnimation(NotchViewModel.spring) { vm?.heightOverrides[pluginID] = CGFloat(h) } }
            ok()
        case let f where f.hasPrefix("proxy."): s.proxy.handle(String(f.dropFirst(6)), args: args, reply: reply)
        case let f where f.hasPrefix("dictation."): s.dictation.handle(String(f.dropFirst(10)), args: args, reply: reply)
        default: reply(nil, "Unknown nook call: \(fn)")
        }
    }

    private static func bridgeJS(pluginInfo: String) -> String {
        """
        (() => {
          const call = (fn, ...args) => window.webkit.messageHandlers.nook.postMessage({ fn, args });
          const listeners = {};
          window.nook = {
            plugin: \(pluginInfo),
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
            dictation: Object.fromEntries(['history','retry','remove','copy','paste','clear','state','toggle'].map(n => [n, (...a) => call('dictation.' + n, ...a)])),
            on: (e, cb) => { (listeners[e] = listeners[e] || []).push(cb); },
            _emit: (e, d) => (listeners[e] || []).forEach(cb => { try { cb(d); } catch (err) { console.error(err); } }),
          };
          const css = `:root{--fg:#fff;--muted:rgba(255,255,255,.55);--card:rgba(255,255,255,.06);--card-hover:rgba(255,255,255,.1);--border:rgba(255,255,255,.08);--accent:#ff9f0a;--good:#30d158;--bad:#ff453a;--radius:14px;color-scheme:dark}
            html,body{background:transparent!important;color:var(--fg);font-family:-apple-system,BlinkMacSystemFont,sans-serif;margin:0;-webkit-user-select:none;overflow:hidden}
            input,textarea,[contenteditable]{-webkit-user-select:text}`;
          const style = document.createElement('style'); style.textContent = css;
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
    static func run(_ command: String, timeout: Double, completion: @escaping ([String: Any]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", command]
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            do { try process.run() } catch {
                return completion(["code": -1, "stdout": "", "stderr": error.localizedDescription])
            }
            let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
            let stdout = out.fileHandleForReading.readDataToEndOfFile()
            let stderr = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            killer.cancel()
            completion(["code": Int(process.terminationStatus),
                        "stdout": String(decoding: stdout, as: UTF8.self),
                        "stderr": String(decoding: stderr, as: UTF8.self)])
        }
    }
}

enum HTTP {
    static func fetch(_ urlString: String, options: [String: Any], completion: @escaping ([String: Any]?, String?) -> Void) {
        guard let url = URL(string: urlString) else { return completion(nil, "Bad URL") }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = options["method"] as? String ?? "GET"
        (options["headers"] as? [String: String])?.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        if let body = options["body"] as? String { request.httpBody = Data(body.utf8) }
        URLSession(configuration: .ephemeral).dataTask(with: request) { data, response, error in
            if let error { return completion(nil, error.localizedDescription) }
            let http = response as? HTTPURLResponse
            let headers = (http?.allHeaderFields as? [String: String]) ?? [:]
            completion(["status": http?.statusCode ?? 0, "headers": headers, "body": String(decoding: data ?? Data(), as: UTF8.self)], nil)
        }.resume()
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
