import Darwin
import Foundation

private func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw PluginEngineError("FAIL: " + message) }
}
private func rejects(line: Int = #line, _ body: () throws -> Void) throws {
    do { try body() } catch { return }; throw PluginEngineError("Expected rejection at line \(line)")
}
private final class Locked<T>: @unchecked Sendable {
    let lock = NSLock(); var value: T
    init(_ value: T) { self.value = value }
    func withValue<R>(_ body: (inout T) -> R) -> R { lock.lock(); defer { lock.unlock() }; return body(&value) }
}

@main enum EngineTests {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        try framing(); try permissions(root); try manifest(root); try supervisor(root); try releasedSupervisor(root); try shell()
        print("PASS: Engine framing, permissions, v2 manifests, supervisor lifecycle/restarts/IPC.")
    }
    static func framing() throws {
        var framer = PluginRPCFramer()
        let request: [String: Any] = ["jsonrpc": "2.0", "id": "unicode", "method": "echo", "params": ["text": "😀\nhello"]]
        let data = try PluginRPCFramer.encode(request)
        var messages: [[String: Any]] = []
        for byte in data { messages += try framer.append(Data([byte])) }
        try expect(messages.count == 1 && (messages[0]["params"] as? [String: String])?["text"] == "😀\nhello", "Fragmented UTF-8 and escaped newlines")
        let combined = try framer.append(data + Data("\r\n".utf8) + data)
        try expect(combined.count == 2, "Multiple frames per read, CRLF and empty lines")
        try rejects { _ = try framer.append(Data("not json\n".utf8)) }
        framer = PluginRPCFramer()
        try rejects { _ = try framer.append(Data("{\"jsonrpc\":\"1.0\",\"method\":\"bad\"}\n".utf8)) }
        framer = PluginRPCFramer()
        try rejects { _ = try framer.append(Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":true,\"error\":{}}\n".utf8)) }
        framer = PluginRPCFramer()
        try rejects { _ = try framer.append(Data(repeating: 65, count: PluginRPCFramer.maximum + 1)) }
        var backoff = PluginRestartBackoff()
        try expect((0..<9).map { _ in backoff.next(uptime: 0) } == [1, 2, 4, 8, 16, 32, 60, 60, 60], "Bounded exponential restart backoff")
        try expect(backoff.next(uptime: 61) == 1, "Healthy uptime resets backoff")
    }
    static func permissions(_ root: URL) throws {
        let m = try PluginManifestV2(json: ["id": "test", "name": "Test", "apiVersion": 2, "permissions": ["clipboard", "network"]], directory: root)
        try rejects { try PluginCapabilityPolicy.check("host.clipboard.read", manifest: m, grant: nil) }
        let grant = PluginPermissionGrant(permissions: m.requested, native: false, fileScopes: [])
        try PluginCapabilityPolicy.check("host.clipboard.read", manifest: m, grant: grant)
        try PluginCapabilityPolicy.check("fetch", manifest: m, grant: grant)
        for method in ["shell", "ai.complete", "files.read", "selection.paste", "secrets.get", "commands.run", "proxy.connect", "unlisted"] {
            try rejects { try PluginCapabilityPolicy.check(method, manifest: m, grant: grant) }
        }
        let revoked = PluginPermissionGrant(permissions: [], native: false, fileScopes: [])
        try rejects { try PluginCapabilityPolicy.check("notch.open", manifest: m, grant: revoked) }
        let helper = try PluginManifestV2(json: ["id": "test", "name": "Test", "apiVersion": 2, "native": ["command": "bin/helper"]], directory: root)
        try expect(!grant.allows(helper), "Adding a helper always requires new trust consent")
    }
    static func manifest(_ root: URL) throws {
        let base: [String: Any] = ["id": "test", "name": "Test", "apiVersion": 2]
        for patch: [String: Any] in [
            ["apiVersion": true], ["apiVersion": 2.5], ["apiVersion": 3],
            ["native": ["command": "../escape"]], ["native": ["command": "/bin/sh"]],
            ["native": ["run": ["node", "-e", "evil"]]], ["native": ["run": ["env", "helper"]]],
            ["native": ["command": "bin/helper", "run": ["node", "main.js"]]],
            ["native": ["command": "bin/helper", "background": true]],
            ["native": ["command": "bin/helper", "background": 1]],
            ["permissions": ["all"]], ["permissions": ["ai", "ai"]],
            ["entry": "../index.html"], ["contributes": ["unknown": []]],
            ["contributes": ["hotkeys": [["id": "x"]]]],
            ["contributes": ["settings": [["id": "x"], ["id": "x"]]]]
        ] {
            do { _ = try PluginManifestV2(json: base.merging(patch) { _, new in new }, directory: root) }
            catch { continue }
            throw PluginEngineError("Accepted invalid manifest: \(patch)")
        }
        let legacy = try PluginManifestV2(json: ["id": "old", "name": "Old"], directory: root)
        try expect(legacy.apiVersion == 1 && legacy.native == nil, "Legacy web manifests still load")
        let valid = try PluginManifestV2(json: base.merging(["native": ["command": ["run": ["python3", "helper.py"]], "background": true, "permissions": ["background"]]]) { _, new in new }, directory: root)
        try expect(valid.native?.run == ["python3", "helper.py"], "Interpreter object form")
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)
        try rejects { _ = try valid.containedURL("link/escape") }
        let dataRoot = root.appendingPathComponent("data")
        let scoped = try PluginFileScope.resolve("draft.txt", dataRoot: dataRoot, scopes: [])
        try expect(scoped.path == PluginPath.resolve(dataRoot).appendingPathComponent("draft.txt").path, "Relative files stay in private data")
        try rejects { _ = try PluginFileScope.resolve("../escape", dataRoot: dataRoot, scopes: []) }
        try rejects { _ = try PluginFileScope.resolve(outside.appendingPathComponent("private.txt").path, dataRoot: dataRoot, scopes: []) }
        try rejects { _ = try PluginFileScope.resolve(root.appendingPathComponent("link/new.txt").path, dataRoot: dataRoot, scopes: [root.path]) }
        _ = try PluginFileScope.resolve(outside.appendingPathComponent("allowed.txt").path, dataRoot: dataRoot, scopes: [outside.path])
    }
    static func supervisor(_ root: URL) throws {
        let source = """
        import sys,json,os,subprocess
        def send(m): print(json.dumps(dict(jsonrpc='2.0',**m)),flush=True)
        send(dict(method='started',params=dict(plugin=os.environ['NOOK_PLUGIN_ID'],data=os.environ['NOOK_DATA_DIR'])))
        send(dict(id=3,method='host.storage.get',params=dict(key='test')))
        for line in sys.stdin:
          m=json.loads(line)
          if m.get('method')=='echo': send(dict(id=m['id'],result=m['params']))
          elif m.get('method')=='spawn':
            child=subprocess.Popen(['/bin/sleep','60']); send(dict(id=m['id'],result=child.pid))
          elif m.get('method')=='crash': os._exit(42)
          elif m.get('id')==3 and 'result' in m: send(dict(method='hostReply',params=dict(value=m['result'])))
        """
        try source.write(to: root.appendingPathComponent("helper.py"), atomically: true, encoding: .utf8)
        let m = try PluginManifestV2(json: ["id": "supervisor", "name": "Supervisor", "apiVersion": 2, "native": ["run": ["python3", "helper.py"]]], directory: root)
        let ready = DispatchSemaphore(value: 0), hostReply = DispatchSemaphore(value: 0), stopped = DispatchSemaphore(value: 0)
        let notices = Locked([String]())
        let helper = PluginHelperProcess(manifest: m, dataDirectory: root.appendingPathComponent("data"), host: { method, params, reply in
            if method == "host.storage.get" { reply("host result", nil) } else { reply(nil, "Denied") }
        }, event: { event, payload in
            if event == "started" { notices.withValue { $0.append(event) }; ready.signal() }
            if event == "hostReply" { hostReply.signal() }
        }, log: { line in if line.contains("exited") { stopped.signal() } }, launcher: CommandLine.arguments.count > 2 ? URL(fileURLWithPath: CommandLine.arguments[2]) : nil)
        let suite = "nook.engine.registry." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let lifecycle = FeatureLifecycle(defaults: defaults)
        lifecycle.register(Feature(id: "plugin:supervisor", title: "Supervisor", summary: "", memoryNote: "", defaultEnabled: false, tabs: ["supervisor"], start: helper.start, stop: helper.stop))
        lifecycle.reconcile()
        try expect(ready.wait(timeout: .now() + 0.05) == .timedOut, "Feature default off never starts the helper")
        lifecycle.setTab("supervisor", enabled: true)
        try expect(ready.wait(timeout: .now() + 5) == .success, "Helper starts")
        try expect(hostReply.wait(timeout: .now() + 5) == .success, "Bidirectional host RPC")
        let response = DispatchSemaphore(value: 0)
        let result = Locked(false)
        helper.call("echo", params: ["hello": "world"]) { value, error in
            result.withValue { $0 = error == nil && (value as? [String: String])?["hello"] == "world" }; response.signal()
        }
        try expect(response.wait(timeout: .now() + 5) == .success && result.withValue { $0 }, "UI to helper request and result")
        let child = Locked(pid_t(0))
        if CommandLine.arguments.count > 2 {
            let spawned = DispatchSemaphore(value: 0)
            helper.call("spawn", params: [:]) { value, _ in child.withValue { $0 = (value as? NSNumber)?.int32Value ?? 0 }; spawned.signal() }
            try expect(spawned.wait(timeout: .now() + 2) == .success && child.withValue { $0 > 0 }, "Helper can spawn a supervised child")
        }
        helper.call("crash", params: [:]) { _, _ in }
        try expect(ready.wait(timeout: .now() + 6) == .success, "Crash is isolated and helper restarts")
        lifecycle.set("plugin:supervisor", enabled: false)
        try expect(lifecycle.disabledTabs.contains("supervisor") && !lifecycle.enabled("plugin:supervisor"), "Feature and tab switches share one state")
        _ = stopped.wait(timeout: .now() + 3)
        Thread.sleep(forTimeInterval: 2.5)
        if child.withValue({ $0 }) > 0 { try expect(kill(child.withValue { $0 }, 0) == -1 && errno == ESRCH, "Crash kills the helper process group, including child processes") }
        try expect(notices.withValue { $0.count } == 2, "Disable stops helper without restart")
        let rejected = DispatchSemaphore(value: 0)
        helper.call("echo", params: [:]) { _, error in if error != nil { rejected.signal() } }
        try expect(rejected.wait(timeout: .now() + 1) == .success, "Stopped helpers reject calls")
    }
    static func shell() throws {
        let launcher = CommandLine.arguments.count > 2 ? URL(fileURLWithPath: CommandLine.arguments[2]) : nil
        let shell = PluginShellCommand(), finished = DispatchSemaphore(value: 0)
        let output = Locked(false)
        shell.run(command: "/usr/bin/python3 -c 'import sys;sys.stderr.write(\"e\"*200000);sys.stdout.write(\"o\"*200000)'", timeout: 10, launcher: launcher) { result in
            output.withValue { $0 = result["code"] as? Int == 0 && (result["stdout"] as? String)?.count == 200000 && (result["stderr"] as? String)?.count == 200000 }
            finished.signal()
        }
        try expect(finished.wait(timeout: .now() + 12) == .success && output.withValue { $0 }, "Shell drains stdout/stderr concurrently without pipe deadlock")
        let long = PluginShellCommand(), cancelled = DispatchSemaphore(value: 0)
        long.run(command: "/bin/sleep 60", timeout: 1, launcher: launcher) { _ in cancelled.signal() }
        try expect(cancelled.wait(timeout: .now() + 5) == .success, "Host shell timeout terminates work")
        let stopped = PluginShellCommand(), stopDone = DispatchSemaphore(value: 0)
        stopped.run(command: "/bin/sleep 60", timeout: 60, launcher: launcher) { _ in stopDone.signal() }
        stopped.cancel()
        try expect(stopDone.wait(timeout: .now() + 5) == .success, "Plugin disable cancels owned shell work")
    }

    static func releasedSupervisor(_ root: URL) throws {
        let manifest = try PluginManifestV2(json: ["id": "released", "name": "Released", "apiVersion": 2,
            "native": ["run": ["python3", "helper.py"]]], directory: root)
        let ready = DispatchSemaphore(value: 0), exited = DispatchSemaphore(value: 0)
        let pid = Locked(pid_t(0))
        var helper: PluginHelperProcess? = PluginHelperProcess(manifest: manifest,
            dataDirectory: root.appendingPathComponent("released-data"), host: { _, _, reply in reply(nil, nil) },
            event: { event, payload in
                if event == "ready" {
                    pid.withValue { $0 = (payload as? [String: Any])?["pid"] as? pid_t ?? 0 }
                    ready.signal()
                }
            }, log: { if $0.contains("exited") { exited.signal() } },
            launcher: CommandLine.arguments.count > 2 ? URL(fileURLWithPath: CommandLine.arguments[2]) : nil)
        weak var released = helper
        helper?.start()
        try expect(ready.wait(timeout: .now() + 5) == .success && pid.withValue { $0 > 0 }, "Released-owner helper starts")
        helper?.stop(); helper = nil // Match registry removal before Process delivers its termination callback.
        try expect(exited.wait(timeout: .now() + 5) == .success, "Supervisor survives owner removal until process cleanup")
        let deadline = Date().addingTimeInterval(4)
        while released != nil && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        try expect(released == nil, "Stopped supervisor releases itself after cleanup")
        try expect(kill(pid.withValue { $0 }, 0) == -1 && errno == ESRCH, "Owner removal leaves no helper process")
    }
}
