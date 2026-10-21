import Foundation
import Darwin

struct AgentFailure: LocalizedError { let message: String; var errorDescription: String? { message } }
@main struct BridgeWorkTests {
    static func wait(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(10)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        precondition(condition(), "Bridge work failed to finish/cancel")
    }
    static func main() throws {
        let scope = PluginWork(), key = UUID()
        var cancellations = 0
        scope.add(key) { cancellations += 1 }
        scope.cancel(); scope.cancel()
        precondition(cancellations == 1)
        precondition(!scope.add(UUID()) { cancellations += 1 } && cancellations == 2)
        do { try scope.perform { preconditionFailure("cancelled work ran") }; preconditionFailure("did not throw") }
        catch is CancellationError {} catch { throw error }

        let root = URL(fileURLWithPath: "/tmp/nook-feature-bridge-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("pid")
        let running = PluginWork()
        var completed = false
        Shell.run("echo $$ > '" + marker.path + "'; /bin/sleep 60", timeout: 120, work: running) { result in
            precondition((result["code"] as? Int) != 0)
            DispatchQueue.main.async { completed = true }
        }
        wait { FileManager.default.fileExists(atPath: marker.path) }
        let pid = Int32(try String(contentsOf: marker).trimmingCharacters(in: .whitespacesAndNewlines))!
        running.cancel()
        wait { completed }
        precondition(kill(pid, 0) != 0 && errno == ESRCH, "page teardown leaves no shell process")
        var skipped = false
        let never = root.appendingPathComponent("must-not-exist")
        Shell.run("touch '" + never.path + "'", timeout: 1, work: scope) { result in
            precondition(result["code"] as? Int == -1)
            DispatchQueue.main.async { skipped = true }
        }
        wait { skipped }
        precondition(!FileManager.default.fileExists(atPath: never.path))
        print("Features: bridge scopes cancel once, reject queued work, kill their test-owned shell process and release its pipes; only /tmp touched")
    }
}
