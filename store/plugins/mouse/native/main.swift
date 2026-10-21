import AppKit
import Darwin

/// stdout is exclusively JSON-RPC; ordinary diagnostics belong on stderr.
enum PluginEvents {
    static let lock = NSLock()
    static func send(_ message: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: message, options: [.sortedKeys]) else { return }
        data.append(10)
        lock.lock(); defer { lock.unlock() }
        try? FileHandle.standardOutput.write(contentsOf: data)
    }
    static func emit(_ event: String, _ payload: Any, to pluginID: String? = nil) { send(["jsonrpc": "2.0", "method": event, "params": payload]) }
}

@main enum MouseHelper {
    static func main() {
        if CommandLine.arguments.contains("--probe") {
            PluginEvents.send(["jsonrpc": "2.0", "method": "probe", "params": ["apiVersion": 2, "feature": "mouse", "eventTapStarted": false]])
            return
        }
        guard ProcessInfo.processInfo.environment["NOOK_PLUGIN_ID"] == "mouse", ProcessInfo.processInfo.environment["NOOK_DATA_DIR"] != nil else {
            FileHandle.standardError.write(Data("Run this helper through Nook.\n".utf8)); return
        }
        _ = fcntl(STDOUT_FILENO, F_SETNOSIGPIPE, 1)
        let mouse = MouseFixService()
        // Protocol tests can query and shut down without touching an event tap or asking for permissions.
        let started = !CommandLine.arguments.contains("--protocol-test")
        if started { mouse.start() }
        signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        let shutdown = { if started { mouse.shutdown() }; exit(0) }
        term.setEventHandler(handler: shutdown); interrupt.setEventHandler(handler: shutdown)
        term.resume(); interrupt.resume()
        DispatchQueue.global(qos: .userInitiated).async {
            while let line = readLine() {
                guard line.utf8.count <= 1_048_576,
                      let message = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                      message["jsonrpc"] as? String == "2.0", let method = message["method"] as? String else { continue }
                guard let id = message["id"] else { continue }
                DispatchQueue.main.async {
                    guard method.hasPrefix("mouse.") else {
                        PluginEvents.send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Unknown method"]]); return
                    }
                    let args = (message["params"] as? [String: Any])?["args"] as? [Any] ?? []
                    mouse.handle(String(method.dropFirst(6)), args: args) { result, error in
                        var response: [String: Any] = ["jsonrpc": "2.0", "id": id]
                        if let error { response["error"] = ["code": -32602, "message": error] } else { response["result"] = result ?? NSNull() }
                        PluginEvents.send(response)
                    }
                }
            }
            DispatchQueue.main.async(execute: shutdown)
        }
        RunLoop.main.run()
        withExtendedLifetime([term, interrupt]) {}
    }
}
