import Foundation

enum CodexLink {
  /// The `codex` command from the user's login shell (bun/npm/brew installs live in different places).
  static func cliPath() -> String? {
    pathLock.lock()
    defer { pathLock.unlock() }
    if pathLoaded { return cachedPath }
    let shell = run("/bin/zsh", ["-lic", "command -v codex"]).trimmingCharacters(
      in: .whitespacesAndNewlines)
    let candidates =
      [shell] + [
        "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
        NSHomeDirectory() + "/.bun/bin/codex", NSHomeDirectory() + "/.local/bin/codex",
      ]
    cachedPath = candidates.first {
      !$0.isEmpty && FileManager.default.isExecutableFile(atPath: $0)
    }
    pathLoaded = true
    return cachedPath
  }

  static func refresh() {
    pathLock.lock()
    defer { pathLock.unlock() }
    cachedPath = nil
    pathLoaded = false
  }
  private static let pathLock = NSLock()
  private static var cachedPath: String?
  private static var pathLoaded = false

  @discardableResult
  private static func run(_ path: String, _ args: [String]) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
  }
}
