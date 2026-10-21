import Darwin
import Foundation

/// One serial state queue per helper; pipe reads/writes never block the UI. The host owns permission checks.
final class PluginHelperProcess: @unchecked Sendable {
    typealias Reply = (Any?, String?) -> Void
    let manifest: PluginManifestV2
    private let dataDirectory: URL
    private let queue: DispatchQueue
    private let writer: DispatchQueue
    private let host: (String, Any, @escaping Reply) -> Void
    private let event: (String, Any) -> Void
    private let log: (String) -> Void
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var errors: FileHandle?
    private var framer = PluginRPCFramer()
    private var pending: [String: Reply] = [:]
    private var wanted = false
    private var generation = UUID()
    private var retry: DispatchWorkItem?
    private var backoff = PluginRestartBackoff()
    private var started = Date()
    private var queuedWrites = 0
    private var hostRequests = 0
    private let launcher: URL?
    private let queueKey = DispatchSpecificKey<Bool>()

    init(manifest: PluginManifestV2, dataDirectory: URL,
         host: @escaping (String, Any, @escaping Reply) -> Void,
         event: @escaping (String, Any) -> Void, log: @escaping (String) -> Void,
         launcher: URL? = Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("nook-cli") : nil) {
        self.manifest = manifest; self.dataDirectory = dataDirectory
        self.host = host; self.event = event; self.log = log
        self.launcher = launcher
        queue = DispatchQueue(label: "nook.helper." + manifest.id)
        writer = DispatchQueue(label: "nook.helper.writer." + manifest.id)
        queue.setSpecific(key: queueKey, value: true)
    }

    func start() { queue.async { self.wanted = true; if self.process == nil && self.retry == nil { self.launch() } } }
    func stop() {
        let work = { self.wanted = false; self.retry?.cancel(); self.retry = nil; self.terminate() }
        if DispatchQueue.getSpecific(key: queueKey) == true { work() } else { queue.sync(execute: work) }
    }
    func notify(_ method: String, _ params: Any) {
        queue.async { if self.process != nil { self.send(["jsonrpc": "2.0", "method": method, "params": params]) } }
    }
    func call(_ method: String, params: Any, reply: @escaping Reply) {
        queue.async {
            guard self.wanted, self.process?.isRunning == true else { return reply(nil, "Helper is stopped or restarting.") }
            guard !method.hasPrefix("host."), !method.isEmpty, method.utf8.count <= 200, self.pending.count < 128 else { return reply(nil, "Invalid helper method or too many pending calls.") }
            let id = UUID().uuidString
            let message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
            do { _ = try PluginRPCFramer.encode(message) } catch { return reply(nil, error.localizedDescription) }
            self.pending[id] = reply
            self.send(message)
            self.queue.asyncAfter(deadline: .now() + 15) {
                if let reply = self.pending.removeValue(forKey: id) { reply(nil, "Helper request timed out after 15 seconds.") }
            }
        }
    }

    private func launch() {
        guard wanted else { return }
        retry = nil
        generation = UUID()
        let token = generation
        do {
            let (executable, arguments) = try manifest.executable()
            try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let task = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
            task.executableURL = launcher ?? executable
            task.arguments = launcher == nil ? arguments : ["_plugin-exec", executable.path] + arguments
            task.currentDirectoryURL = manifest.directory
            // Do not leak the app's API keys or arbitrary injected environment into plugins.
            let parent = ProcessInfo.processInfo.environment
            var env = Dictionary(uniqueKeysWithValues: ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG"].compactMap { key in parent[key].map { (key, $0) } })
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            env["NOOK_PLUGIN_ID"] = manifest.id; env["NOOK_PLUGIN_DIR"] = manifest.directory.path; env["NOOK_DATA_DIR"] = dataDirectory.path
            task.environment = env
            task.standardInput = stdin; task.standardOutput = stdout; task.standardError = stderr
            let out = stdout.fileHandleForReading, err = stderr.fileHandleForReading
            out.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                self?.queue.async { [weak self] in
                    guard let self, self.generation == token else { return }
                    if data.isEmpty { handle.readabilityHandler = nil; return }
                    do { for message in try self.framer.append(data) { self.receive(message, token: token) } }
                    catch { self.log(error.localizedDescription); self.terminate() }
                }
            }
            err.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil; return }
                self?.log(String(decoding: data.prefix(8192), as: UTF8.self))
            }
            task.terminationHandler = { [weak self] task in
                self?.queue.async { [weak self] in
                    guard let self, self.generation == token else { return }
                    self.log("Helper exited (\(task.terminationStatus)).")
                    if self.launcher != nil {
                        let pid = task.processIdentifier
                        kill(-pid, SIGTERM)
                        self.queue.asyncAfter(deadline: .now() + 2) { kill(-pid, SIGKILL) }
                    }
                    self.cleanup()
                    self.scheduleRestart()
                }
            }
            process = task; input = stdin.fileHandleForWriting; output = out; errors = err
            _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            try task.run()
            stdin.fileHandleForReading.closeFile(); stdout.fileHandleForWriting.closeFile(); stderr.fileHandleForWriting.closeFile()
            started = Date()
            log("Helper started (pid \(task.processIdentifier)).")
            event("ready", ["pid": task.processIdentifier])
            send(["jsonrpc": "2.0", "method": "host.ready", "params": ["apiVersion": 2, "pluginID": manifest.id]])
        } catch {
            log("Couldn't start helper: \(error.localizedDescription)")
            cleanup(); scheduleRestart()
        }
    }

    private func scheduleRestart() {
        guard wanted else { return }
        let delay = backoff.next(uptime: Date().timeIntervalSince(started))
        log("Restarting helper in \(Int(delay))s.")
        let work = DispatchWorkItem { [weak self] in self?.launch() }
        retry = work; queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func receive(_ message: [String: Any], token: UUID) {
        if let method = message["method"] as? String {
            let params = message["params"] ?? NSNull()
            if method.hasPrefix("host.") {
                let id = message["id"]
                guard hostRequests < 128 else {
                    if let id { send(["jsonrpc": "2.0", "id": id, "error": ["code": -32000, "message": "Too many pending host requests"]]) }
                    return
                }
                hostRequests += 1
                host(method, params) { [weak self] value, error in
                    self?.queue.async { [weak self] in
                        guard let self, self.generation == token else { return }
                        self.hostRequests = max(0, self.hostRequests - 1)
                        guard let id else { return }
                        var response: [String: Any] = ["jsonrpc": "2.0", "id": id]
                        if let error { response["error"] = ["code": -32001, "message": error] }
                        else { response["result"] = value ?? NSNull() }
                        self.send(response)
                    }
                }
            } else if message["id"] == nil { event(method, params) }
            else { send(["jsonrpc": "2.0", "id": message["id"]!, "error": ["code": -32601, "message": "Host requests must use host.*"]]) }
        } else if let id = message["id"] as? String, let reply = pending.removeValue(forKey: id) {
            let error = (message["error"] as? [String: Any])?["message"] as? String
            reply(message["result"], error ?? (message["error"] == nil ? nil : "Helper returned an error."))
        }
    }

    private func send(_ message: [String: Any]) {
        guard let input else { return }
        do {
            let data = try PluginRPCFramer.encode(message)
            guard queuedWrites < 128 else { log("Helper input queue overflow."); terminate(); return }
            queuedWrites += 1
            writer.async { [weak self] in
                do { try input.write(contentsOf: data) } catch { self?.log("Helper input closed: \(error.localizedDescription)") }
                self?.queue.async { [weak self] in self?.queuedWrites = max(0, (self?.queuedWrites ?? 0) - 1) }
            }
        } catch { log(error.localizedDescription) }
    }

    private func terminate() {
        guard let task = process else { return }
        // Closing stdin is also the protocol's clean shutdown signal. Helpers must stop on EOF.
        try? input?.close(); input = nil
        guard task.isRunning else { return }
        let pid = task.processIdentifier
        let children = Self.descendants(pid)
        if launcher != nil { kill(-pid, SIGTERM) }
        children.reversed().forEach { kill($0, SIGTERM) }
        task.terminate()
        queue.asyncAfter(deadline: .now() + 2) {
            guard task.isRunning else { return }
            (children + Self.descendants(pid)).reversed().forEach { kill($0, SIGKILL) }
            kill(pid, SIGKILL)
        }
    }

    private func cleanup() {
        output?.readabilityHandler = nil; errors?.readabilityHandler = nil
        try? input?.close(); try? output?.close(); try? errors?.close()
        input = nil; output = nil; errors = nil; process = nil; framer = PluginRPCFramer(); hostRequests = 0
        let callbacks = Array(pending.values); pending.removeAll()
        callbacks.forEach { $0(nil, "Helper stopped.") }
    }

    private static func descendants(_ pid: pid_t, depth: Int = 0) -> [pid_t] {
        guard depth < 16 else { return [] }
        let count = proc_listchildpids(pid, nil, 0)
        guard count > 0 else { return [] }
        var children = [pid_t](repeating: 0, count: Int(count) + 32)
        let actual = children.withUnsafeMutableBytes { proc_listchildpids(pid, $0.baseAddress, Int32($0.count)) }
        guard actual > 0 else { return [] }
        let direct = Array(children.prefix(Int(actual))).filter { $0 > 0 }
        return direct + direct.flatMap { descendants($0, depth: depth + 1) }
    }
}
