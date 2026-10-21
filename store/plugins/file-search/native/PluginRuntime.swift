import AppKit
import Darwin

/// Package-local preferences. Legacy defaults are read once; every write stays in NOOK_DATA_DIR.
final class PluginDefaults {
    static let standard = PluginDefaults()
    static let didChangeNotification = UserDefaults.didChangeNotification
    private let lock = NSRecursiveLock()
    private var values: [String: Any] = [:]
    private var fallback: [String: Any] = [:]
    private let file: URL
    init() {
        file = PluginRuntime.data.appendingPathComponent("preferences.plist")
        if let data = try? Data(contentsOf: file), let saved = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] { values = saved }
    }
    func object(forKey key: String) -> Any? { lock.lock(); defer { lock.unlock() }; return values[key] ?? fallback[key] }
    func string(forKey key: String) -> String? { object(forKey: key) as? String }
    func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
    func stringArray(forKey key: String) -> [String]? { object(forKey: key) as? [String] }
    func dictionary(forKey key: String) -> [String: Any]? { object(forKey: key) as? [String: Any] }
    func bool(forKey key: String) -> Bool { (object(forKey: key) as? NSNumber)?.boolValue ?? false }
    func integer(forKey key: String) -> Int { (object(forKey: key) as? NSNumber)?.intValue ?? 0 }
    func double(forKey key: String) -> Double { (object(forKey: key) as? NSNumber)?.doubleValue ?? 0 }
    func register(defaults: [String: Any]) { lock.lock(); defer { lock.unlock() }; fallback.merge(defaults) { _, new in new } }
    func set(_ value: Any?, forKey key: String) {
        lock.lock()
        if let value { values[key] = value } else { values.removeValue(forKey: key) }
        save(); lock.unlock()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
    func removeObject(forKey key: String) { set(nil, forKey: key) }
    func merge(_ settings: [String: Any]) {
        lock.lock(); values.merge(settings) { _, new in new }; save(); lock.unlock()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
    private func save() {
        do {
            try FileManager.default.createDirectory(at: PluginRuntime.data, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let bytes = try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
            try bytes.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch { PluginEvents.emit("error", error.localizedDescription) }
    }
    func migrate(prefixes: [String], legacy: [String: Any]? = nil) {
        lock.lock()
        guard !bool(forKey: "migration.v2") else { lock.unlock(); return }
        let old = legacy ?? UserDefaults.standard.persistentDomain(forName: "com.yusuf.nook") ?? [:]
        for (key, value) in old where prefixes.contains(where: key.hasPrefix) && values[key] == nil { values[key] = value }
        values["migration.v2"] = true
        save(); lock.unlock()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}

enum PluginEvents {
    private static let lock = NSLock()
    static func send(_ message: [String: Any]) {
        guard var bytes = try? JSONSerialization.data(withJSONObject: message, options: [.sortedKeys]), bytes.count < 1_048_576 else { return }
        bytes.append(10); lock.lock(); defer { lock.unlock() }
        try? FileHandle.standardOutput.write(contentsOf: bytes)
    }
    static func emit(_ event: String, _ payload: Any, to pluginID: String? = nil) { send(["jsonrpc": "2.0", "method": event, "params": payload]) }
}

/// This registry lives in the helper process. No feature namespace is installed in Nook.
enum BridgeRegistry {
    typealias Reply = (Any?, String?) -> Void
    typealias Handler = (String, [Any], String, @escaping Reply) -> Void
    static var handlers: [String: Handler] = [:]
    static func register(_ namespace: String, functions: [String], handler: @escaping Handler) { handlers[namespace] = handler }
    static func unregister(_ namespace: String) { handlers.removeValue(forKey: namespace) }
}
struct TabHotkey: Codable { var keyCode: Int; var modifiers: UInt64; var display: String }
enum LinkCatcher { static var ignoreClipboardUntil = Date.distantPast }
final class Services {
    static let shared = Services()
    static var supportDir: URL { PluginRuntime.data }
    func closeNotches() { PluginRuntime.host("notch.close") }
}
enum Features {
    static let shared = FeaturesState()
    struct FeaturesState { func enabled(_ id: String) -> Bool { PluginDefaults.standard.object(forKey: "capture." + id) as? Bool ?? true } }
}
enum PluginRuntime {
    static let data = URL(fileURLWithPath: ProcessInfo.processInfo.environment["NOOK_DATA_DIR"] ?? "/tmp/nook-unconfigured", isDirectory: true)
    static let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["NOOK_PLUGIN_DIR"] ?? ".", isDirectory: true)
    static let id = ProcessInfo.processInfo.environment["NOOK_PLUGIN_ID"] ?? ""
    static var scopes: [String] = []
    static var context = ""
    static var onReady: () -> Void = {}
    static var onStop: () -> Void = {}
    static var onEvent: (String, [String: Any]) -> Void = { _, _ in }
    static var custom: (String, [String: Any], @escaping BridgeRegistry.Reply) -> Bool = { _, _, _ in false }
    private static var pending: [String: BridgeRegistry.Reply] = [:]
    private static var next = 0
    static func host(_ method: String, _ params: [String: Any] = [:], reply: @escaping BridgeRegistry.Reply = { _, _ in }) {
        guard pending.count < 64 else { reply(nil, "Too many host requests."); return }
        next += 1; let key = "helper-\(next)"; pending[key] = reply
        PluginEvents.send(["jsonrpc": "2.0", "id": key, "method": "host." + method, "params": params])
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { pending.removeValue(forKey: key)?(nil, "Host request timed out.") }
    }
    static func copyLegacy(_ source: URL, to destination: URL) throws {
        guard !FileManager.default.fileExists(atPath: destination.path), FileManager.default.fileExists(atPath: source.path) else { return }
        let manager = FileManager.default
        // A copied symlink could redirect later cache/history writes back into legacy user data.
        guard (try source.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else { throw CocoaError(.fileReadInvalidFileName) }
        if let entries = manager.enumerator(at: source, includingPropertiesForKeys: [.isSymbolicLinkKey], errorHandler: { _, _ in false }) {
            for case let entry as URL in entries where (try entry.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == true { throw CocoaError(.fileReadInvalidFileName) }
        }
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let stage = destination.deletingLastPathComponent().appendingPathComponent(".migration-" + UUID().uuidString)
        try manager.copyItem(at: source, to: stage)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stage.path)
        try manager.moveItem(at: stage, to: destination)

    }
    static func run() {
        guard !id.isEmpty, ProcessInfo.processInfo.environment["NOOK_DATA_DIR"] != nil else { return }
        if !CommandLine.arguments.contains("--protocol-test") { NSApplication.shared.setActivationPolicy(.accessory) }
        _ = fcntl(STDOUT_FILENO, F_SETNOSIGPIPE, 1)
        signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        let shutdown = { onStop(); exit(0) }
        term.setEventHandler(handler: shutdown); interrupt.setEventHandler(handler: shutdown); term.resume(); interrupt.resume()
        DispatchQueue.global(qos: .userInitiated).async {
            var buffer = Data()
            var bytes = [UInt8](repeating: 0, count: 65536)
            while true {
                let count = Darwin.read(STDIN_FILENO, &bytes, bytes.count)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { break }
                buffer.append(contentsOf: bytes.prefix(count))
                while let end = buffer.firstIndex(of: 10) {
                    let frame = buffer.prefix(upTo: end); buffer.removeSubrange(...end)
                    guard frame.count <= 1_048_576, let message = (try? JSONSerialization.jsonObject(with: frame)) as? [String: Any], message["jsonrpc"] as? String == "2.0" else { continue }
                    DispatchQueue.main.async { receive(message) }
                }
                if buffer.count > 1_048_576 { break }
            }
            DispatchQueue.main.async(execute: shutdown)
        }
        RunLoop.main.run(); withExtendedLifetime([term, interrupt]) {}
    }
    private static func receive(_ message: [String: Any]) {
        guard let method = message["method"] as? String else {
            if let key = message["id"] as? String { pending.removeValue(forKey: key)?(message["result"], (message["error"] as? [String: Any])?["message"] as? String) }; return
        }
        let params = message["params"] as? [String: Any] ?? [:]
        if method == "host.ready" {
            host("settings.get") { value, error in
                guard error == nil else { PluginEvents.emit("error", error!); return }
                // Existing migrated keys win once. Persist them to the generic Settings form before starting work.
                let settings = value as? [String: Any] ?? [:]
                if !PluginDefaults.standard.bool(forKey: "settings.imported") {
                    for (key, value) in settings {
                        if let migrated = PluginDefaults.standard.object(forKey: key) { host("settings.set", ["key": key, "value": migrated]) }
                        else { PluginDefaults.standard.set(value, forKey: key) }
                    }
                    PluginDefaults.standard.set(true, forKey: "settings.imported")
                } else { PluginDefaults.standard.merge(settings) }
                if CommandLine.arguments.contains("--protocol-test") { PluginEvents.emit("ready", NSNull()) } else { onReady() }
            }; return
        }
        if method == "host.event" {
            let event = params["event"] as? String ?? "", info = params["data"] as? [String: Any] ?? [:]
            if event == "settings" { PluginDefaults.standard.merge(info) }
            if event == "beforeOpen" { context = info["context"] as? String ?? "" }
            onEvent(event, info); return
        }
        guard let requestID = message["id"] else { return }
        let reply: BridgeRegistry.Reply = { result, error in
            var response: [String: Any] = ["jsonrpc": "2.0", "id": requestID]
            if let error { response["error"] = ["code": -32602, "message": error] } else { response["result"] = result ?? NSNull() }
            if let bytes = try? JSONSerialization.data(withJSONObject: response), bytes.count < 1_048_576 { PluginEvents.send(response) }
            else { PluginEvents.send(["jsonrpc": "2.0", "id": requestID, "error": ["code": -32000, "message": "Response exceeds the 1 MiB transport limit. Narrow the query."]]) }
        }
        if custom(method, params, reply) { return }
        guard let dot = method.firstIndex(of: "."), let handler = BridgeRegistry.handlers[String(method[..<dot])] else {
            PluginEvents.send(["jsonrpc": "2.0", "id": requestID, "error": ["code": -32601, "message": "Unknown method"]]); return
        }
        handler(String(method[method.index(after: dot)...]), params["args"] as? [Any] ?? [], id, reply)
    }
}
