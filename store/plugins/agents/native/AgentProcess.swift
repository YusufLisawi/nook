import Darwin
import Foundation

/// A dedicated process group per turn, plus descendant enumeration for tools which create their own group.
/// All callbacks arrive on the main queue; stdout/stderr are drained independently before completion.
final class AgentProcess: @unchecked Sendable {
  private(set) var pid: pid_t = 0
  private var finished = false
  private var cancelled = false

  func start(
    executable: String, arguments: [String], directory: String, prompt: String,
    onLine: @escaping (Data) -> Void, onExit: @escaping (Int32, String) -> Void
  ) throws {
    let input = Pipe()
    let output = Pipe()
    let errors = Pipe()
    var actions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    posix_spawn_file_actions_init(&actions)
    posix_spawnattr_init(&attributes)
    defer {
      posix_spawn_file_actions_destroy(&actions)
      posix_spawnattr_destroy(&attributes)
    }
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
    posix_spawnattr_setpgroup(&attributes, 0)
    posix_spawn_file_actions_addchdir_np(&actions, directory)
    let descriptors = [
      (input.fileHandleForReading, STDIN_FILENO), (output.fileHandleForWriting, STDOUT_FILENO),
      (errors.fileHandleForWriting, STDERR_FILENO),
    ]
    for (handle, target) in descriptors {
      posix_spawn_file_actions_adddup2(&actions, handle.fileDescriptor, target)
    }
    for pipe in [input, output, errors] {
      posix_spawn_file_actions_addclose(&actions, pipe.fileHandleForReading.fileDescriptor)
      posix_spawn_file_actions_addclose(&actions, pipe.fileHandleForWriting.fileDescriptor)
    }
    var environment = ProcessInfo.processInfo.environment
    // A GUI app's PATH often omits node/bun/brew, including the interpreter in Codex's shebang.
    environment["PATH"] = [
      URL(fileURLWithPath: executable).deletingLastPathComponent().path,
      NSHomeDirectory() + "/.bun/bin", NSHomeDirectory() + "/.local/bin",
      "/opt/homebrew/bin", "/usr/local/bin", environment["PATH"] ?? "/usr/bin:/bin",
    ].joined(separator: ":")
    let argv = ([executable] + arguments).map { strdup($0) } + [nil]
    let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer {
      argv.forEach { free($0) }
      envp.forEach { free($0) }
    }
    let result = argv.withUnsafeBufferPointer { args in
      envp.withUnsafeBufferPointer { env in
        posix_spawn(
          &pid, executable, &actions, &attributes,
          UnsafeMutablePointer(mutating: args.baseAddress!),
          UnsafeMutablePointer(mutating: env.baseAddress!))
      }
    }
    guard result == 0 else {
      throw AgentFailure(message: "Couldn't start Codex: \(String(cString: strerror(result)))")
    }
    input.fileHandleForReading.closeFile()
    output.fileHandleForWriting.closeFile()
    errors.fileHandleForWriting.closeFile()
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      var buffer = Data()
      while true {
        let chunk = output.fileHandleForReading.availableData
        if chunk.isEmpty { break }
        buffer.append(chunk)
        while let end = buffer.firstIndex(of: 10) {
          let line = Data(buffer[..<end])
          buffer.removeSubrange(...end)
          DispatchQueue.main.async { onLine(line) }
        }
      }
      if !buffer.isEmpty {
        let line = buffer
        DispatchQueue.main.async { onLine(line) }
      }
      output.fileHandleForReading.closeFile()
      group.leave()
    }
    let diagnostics = AgentDiagnostics()
    group.enter()
    DispatchQueue.global(qos: .utility).async {
      while true {
        let chunk = errors.fileHandleForReading.availableData
        if chunk.isEmpty { break }
        diagnostics.append(chunk)
      }
      errors.fileHandleForReading.closeFile()
      group.leave()
    }
    // Blocking stdin writes belong off the main queue (a long prompt may exceed a pipe buffer).
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      // Prevent SIGPIPE if the CLI exits before accepting the prompt.
      _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
      try? input.fileHandleForWriting.write(contentsOf: Data(prompt.utf8))
      input.fileHandleForWriting.closeFile()
      group.leave()
    }
    let childPID = pid
    DispatchQueue.global(qos: .utility).async {
      var status: Int32 = 0
      while waitpid(childPID, &status, 0) == -1 && errno == EINTR {}
      group.wait()
      let code = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
      DispatchQueue.main.async {
        self.finished = true
        onExit(code, diagnostics.text)
      }
    }
  }

  func cancel() {
    guard pid > 0, !finished, !cancelled else { return }
    cancelled = true
    Self.terminateTree(pid)
  }

  static func terminateTree(_ pid: pid_t) {
    guard pid > 0 else { return }
    kill(pid, SIGSTOP)
    kill(-pid, SIGSTOP)
    let descendants = Self.descendants(of: pid)
    // Stop leaves first, then the CLI, so grandchildren cannot escape by being reparented.
    for child in descendants.reversed() { kill(child, SIGKILL) }
    kill(-pid, SIGKILL)
    kill(pid, SIGKILL)
  }

  private static func descendants(of parent: pid_t) -> [pid_t] {
    // Unlike proc_listpids, proc_listchildpids returns a PID count, not a byte count.
    let capacity = proc_listchildpids(parent, nil, 0)
    guard capacity > 0 else { return [] }
    var children = [pid_t](repeating: 0, count: Int(capacity) + 32)
    let count = children.withUnsafeMutableBytes {
      proc_listchildpids(parent, $0.baseAddress, Int32($0.count))
    }
    guard count > 0 else { return [] }
    let direct = children.prefix(Int(count)).filter { $0 > 0 }
    return direct.flatMap { child -> [pid_t] in
      kill(child, SIGSTOP)
      return [child] + descendants(of: child)
    }
  }
}

private final class AgentDiagnostics: @unchecked Sendable {
  // One stderr reader; only read after its dispatch group completes. Bound noisy CLI logs.
  private var data = Data()
  func append(_ chunk: Data) {
    data.append(chunk)
    if data.count > 16_384 { data = data.suffix(16_384) }
  }
  var text: String { String(decoding: data, as: UTF8.self) }
}
