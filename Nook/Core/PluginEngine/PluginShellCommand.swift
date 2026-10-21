import Darwin
import Foundation

/// V2 shell calls are owned by their plugin, bounded, drained concurrently and cancellable on disable.
final class PluginShellCommand: @unchecked Sendable {
    private let queue = DispatchQueue(label: "nook.plugin.shell")
    private var process: Process?
    private var cancelled = false
    private var groupPID: pid_t = 0
    private var timeoutWork: DispatchWorkItem?
    private final class Capture: @unchecked Sendable {
        let lock = NSLock(); var data = Data()
        func append(_ chunk: Data) {
            lock.lock(); defer { lock.unlock() }
            data.append(chunk.prefix(max(0, 1_048_576 - data.count)))
        }
        var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
    }
    func run(command: String, timeout: TimeInterval, launcher: URL?, completion: @escaping ([String: Any]) -> Void) {
        queue.async {
            guard !self.cancelled else { completion(["code": -1, "stdout": "", "stderr": "Cancelled"]); return }
            let task = Process(), output = Pipe(), errors = Pipe()
            task.executableURL = launcher ?? URL(fileURLWithPath: "/bin/zsh")
            task.arguments = (launcher == nil ? [] : ["_plugin-exec", "/bin/zsh"]) + ["-lc", command]
            task.standardInput = FileHandle.nullDevice; task.standardOutput = output; task.standardError = errors
            let stdout = Capture(), stderr = Capture(), drains = DispatchGroup()
            drains.enter(); drains.enter()
            task.terminationHandler = { task in
                self.queue.async {
                    self.timeoutWork?.cancel(); self.timeoutWork = nil
                    if self.groupPID > 0 {
                        let group = self.groupPID
                        kill(-group, SIGTERM)
                        self.queue.asyncAfter(deadline: .now() + 2) { kill(-group, SIGKILL) }
                    }
                    drains.notify(queue: self.queue) {
                        task.terminationHandler = nil
                        self.process = nil
                        completion(["code": Int(task.terminationStatus), "stdout": stdout.text, "stderr": stderr.text])
                    }
                }
            }
            self.process = task
            do { try task.run() } catch { task.terminationHandler = nil; self.process = nil; completion(["code": -1, "stdout": "", "stderr": error.localizedDescription]); return }
            self.groupPID = launcher == nil ? 0 : task.processIdentifier
            output.fileHandleForWriting.closeFile(); errors.fileHandleForWriting.closeFile()
            for (handle, capture) in [(output.fileHandleForReading, stdout), (errors.fileHandleForReading, stderr)] {
                DispatchQueue.global(qos: .utility).async {
                    while true { let data = handle.availableData; if data.isEmpty { break }; capture.append(data) }
                    try? handle.close(); drains.leave()
                }
            }
            let killer = DispatchWorkItem { self.terminate() }
            self.timeoutWork = killer
            self.queue.asyncAfter(deadline: .now() + timeout, execute: killer)
        }
    }
    func cancel() { queue.sync { cancelled = true; terminate() } }
    private func terminate() {
        guard let process, process.isRunning else { return }
        let pid = process.processIdentifier, group = groupPID
        if group > 0 { kill(-group, SIGTERM) }
        process.terminate()
        queue.asyncAfter(deadline: .now() + 2) {
            if group > 0 { kill(-group, SIGKILL) }
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }
}
