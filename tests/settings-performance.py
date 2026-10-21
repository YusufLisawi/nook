#!/usr/bin/env python3
"""Exercise production Settings caches and persistence in /tmp; never start the app."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
stubs = r'''
import Foundation

enum CodexLink {
    enum State { case notInstalled }
    static func refresh() {}
    static func state() -> State { .notInstalled }
    static func cliPath() -> String? { nil }
}
enum ToolsInstaller {
    static var cliInstalled: Bool { false }
    static var cliOnPath: Bool { false }
    static var agents: [(name: String, dir: URL, always: Bool)] { [] }
    static func skillInstalled(in url: URL) -> Bool { false }
}
enum MicRecorder {
    struct Mic { let id: String; let name: String }
    static func microphones() -> [Mic] { [] }
}
enum Services {
    static let supportDir = URL(fileURLWithPath: CommandLine.arguments[1])
}
struct TabItem {
    let id: String
    let settings: [PluginSetting]
}
enum PluginEvents {
    static var last: [String: Any] = [:]
    static func emit(_ event: String, _ payload: Any, to id: String?) { last = payload as? [String: Any] ?? [:] }
}
// The production color convenience initializer is unrelated to storage.
import SwiftUI
extension Color { init(css: String) { self = .clear } }
'''
test = r'''
import Foundation

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return storage }
    @discardableResult func increment() -> Int { lock.lock(); defer { lock.unlock() }; storage += 1; return storage }
}

@main struct Checks {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ description: String) {
            precondition(condition(), description)
            checks += 1
        }
        let counter = Counter()
        let snapshot = SettingsSnapshot<Int> {
            precondition(!Thread.isMainThread, "Discovery must not block the UI thread")
            Thread.sleep(forTimeInterval: 0.15)
            return counter.increment()
        }
        let start = Date()
        let first = Task { await snapshot.refresh() }
        let second = Task { await snapshot.refresh() }
        try await Task.sleep(nanoseconds: 20_000_000)
        check(snapshot.value == nil && Date().timeIntervalSince(start) < 0.12, "Main actor responds during cold discovery")
        check(snapshot.refreshing, "Cold discovery exposes a loading state")
        await first.value
        await second.value
        check(snapshot.value == 1 && counter.value == 1, "Concurrent refreshes share one discovery")
        check(!snapshot.refreshing, "Loading state clears after discovery")
        let cachedStart = Date()
        for _ in 0..<1000 { await snapshot.refresh() }
        let cachedMS = Date().timeIntervalSince(cachedStart) * 1000 / 1000
        check(counter.value == 1, "Pane switches reuse the snapshot without discovery")
        await snapshot.refresh(force: true)
        check(counter.value == 2 && snapshot.value == 2, "Explicit refresh invalidates the cached status")
        let beforeInvalidation = Task { await snapshot.refresh(force: true) }
        try await Task.sleep(nanoseconds: 20_000_000)
        await snapshot.refresh(force: true)
        await beforeInvalidation.value
        check(counter.value == 4 && snapshot.value == 4, "Changes during discovery trigger one follow-up and all callers await the fresh result")
        let missingCounter = Counter()
        let missing = SettingsSnapshot<String?> { missingCounter.increment(); return nil }
        await missing.refresh()
        await missing.refresh()
        check(missingCounter.value == 1 && missing.value != nil, "Missing tools are cached as completed results")
        let expiredCounter = Counter()
        let expired = SettingsSnapshot(lifetime: -1) { expiredCounter.increment() }
        await expired.refresh()
        await expired.refresh()
        check(expiredCounter.value == 2, "Expired status refreshes on the next visit")

        let writer = SettingsPersistence(delay: 60)
        let written = Counter()
        let latest = Counter()
        for index in 0..<100 {
            writer.submit(id: "same-file") { written.increment(); if index == 99 { latest.increment() } }
        }
        writer.flush()
        check(written.value == 1 && latest.value == 1, "Rapid writes coalesce to the latest snapshot")
        writer.submit(id: "first-file") { written.increment() }
        writer.submit(id: "second-file") { written.increment() }
        writer.flush()
        check(written.value == 3, "Independent files are retained and flushed")
        let offThread = DispatchSemaphore(value: 0)
        SettingsPersistence(delay: 0).submit(id: "background") {
            precondition(!Thread.isMainThread, "Normal persistence must run off the UI thread")
            offThread.signal()
        }
        check(offThread.wait(timeout: .now() + 2) == .success, "Background persistence completes without a flush")

        let file = Services.supportDir.appendingPathComponent("test.json")
        let baselineFile = Services.supportDir.appendingPathComponent("typing-baseline.json")
        var baseline = ["existing": 5]
        let baselineStart = Date()
        for index in 0..<1000 {
            baseline["edited"] = index
            try JSONEncoder().encode(baseline).write(to: baselineFile, options: .atomic)
        }
        let baselineMS = Date().timeIntervalSince(baselineStart) * 1000 / 1000
        try JSONEncoder().encode(["existing": 5]).write(to: file)
        let store = SettingsJSONFile<[String: Int]>(url: { file }, fallback: [:], permissions: 0o600)
        check(store.read()["existing"] == 5, "Cold store reads existing user values")
        let typingStart = Date()
        for index in 0..<1000 { store.update { $0["edited"] = index } }
        let typingMS = Date().timeIntervalSince(typingStart) * 1000 / 1000
        check(store.read()["edited"] == 999 && store.read()["existing"] == 5, "Edits are immediately visible and retain sibling keys")
        DispatchQueue.concurrentPerform(iterations: 100) { _ in store.update { $0["count", default: 0] += 1 } }
        SettingsPersistence.shared.flush()
        let decoded = try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: file))
        check(decoded["count"] == 100 && decoded["edited"] == 999, "Concurrent edits and quit flush preserve the final snapshot")
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        check(permissions == 0o600, "Secret-file permissions remain private")
        store.update { $0.removeValue(forKey: "edited") }
        check(store.read()["edited"] == nil, "Clearing a value updates the live snapshot")

        let tab = TabItem(id: "test-plugin", settings: [
            PluginSetting(key: "name", label: "Name", type: .text, default: .string("Default")),
            PluginSetting(key: "enabled", label: "Enabled", type: .toggle, default: .bool(true))
        ])
        _ = PluginSettingsStore.values(for: tab)
        PluginSettingsStore.set(tab, "name", .string("Edited"))
        PluginSettingsStore.set(tab, "enabled", .bool(false))
        check(PluginSettingsStore.values(for: tab)["name"] == .string("Edited"), "Plugin edits are readable before persistence")
        check(PluginEvents.last["enabled"] as? Bool == false && PluginEvents.last["name"] as? String == "Edited", "Live plugin event includes all edited options")
        SettingsPersistence.shared.flush()
        let pluginFile = Services.supportDir.appendingPathComponent("Data/test-plugin.settings.json")
        let saved = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: pluginFile))
        check(saved["name"] == .string("Edited") && saved["enabled"] == .bool(false), "Plugin settings retain their existing disk format")
        PluginSettingsStore.reset(tab)
        check(PluginSettingsStore.values(for: tab)["name"] == .string("Default"), "Reset immediately restores manifest defaults")
        SettingsPersistence.shared.flush()
        let reset = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: pluginFile))
        check(reset.isEmpty, "Reset saves an empty override dictionary")
        print("Passed \(checks) Settings performance/persistence checks using only temporary files.")
        print(String(format: "Cached status refresh: %.4f ms/call; synchronous atomic field save: %.4f ms/edit → cached background field save: %.4f ms/edit (1000 iterations each).", cachedMS, baselineMS, typingMS))
    }
}
'''

codex_stubs = r'''
import AppKit

// Shadow only the shell process and executable checks: no shell or AppleScript is executed by this test.
final class FileManager {
    static let `default` = FileManager()
    var executablePaths: Set<String> = []
    func isExecutableFile(atPath path: String) -> Bool { executablePaths.contains(path) }
}
final class Process {
    static var launches = 0
    var executableURL: URL?
    var arguments: [String] = []
    var standardOutput: Any?
    var standardError: Any?
    func run() throws {
        Self.launches += 1
        let pipe = standardOutput as! Pipe
        try pipe.fileHandleForWriting.write(contentsOf: Data("/tmp/mock-codex".utf8))
        try pipe.fileHandleForWriting.close()
    }
    func waitUntilExit() {}
}
enum OpenAITranscriber {
    enum Auth { case chatgpt; case apiKey }
    static let authURL = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("missing-auth.json")
    static func readAuth() -> Auth? { nil }
}
enum AIBrain {
    static func complete(provider: String, model: String, effort: String, prompt: String,
                         onDelta: (String) -> Void) async throws -> String { "unused" }
}
'''
codex_test = r'''
import Foundation

@main struct CodexChecks {
    static func main() {
        precondition(CodexLink.cliPath() == nil)
        precondition(CodexLink.cliPath() == nil && Process.launches == 1, "A missing CLI must be cached")
        precondition(CodexLink.state() == .notInstalled && Process.launches == 1, "Signed-out status must reuse a missing-path result")
        FileManager.default.executablePaths.insert("/tmp/mock-codex")
        CodexLink.refresh()
        precondition(CodexLink.cliPath() == "/tmp/mock-codex" && Process.launches == 2, "Refresh must detect a newly installed CLI")
        precondition(CodexLink.cliPath() == "/tmp/mock-codex" && Process.launches == 2, "Installed CLI must also be cached")
        FileManager.default.executablePaths.removeAll()
        CodexLink.refresh()
        precondition(CodexLink.cliPath() == nil && Process.launches == 3, "Refresh must detect removal")
        precondition(CodexLink.cliPath() == nil && Process.launches == 3, "Removal must remain cached")
        print("Passed 7 Codex discovery checks with mocked processes; no shell, Terminal, or auth files used.")
    }
}
'''

with tempfile.TemporaryDirectory(prefix="nook-settings-performance-", dir="/tmp") as temp:
    temp = Path(temp)
    (temp / "Stubs.swift").write_text(stubs)
    (temp / "Checks.swift").write_text(test)
    executable = temp / "settings-performance"
    subprocess.run([
        "xcrun", "swiftc", "-swift-version", "5", "-warnings-as-errors", "-O", "-parse-as-library",
        str(root / "Nook/Core/SettingsPersistence.swift"),
        str(root / "Nook/Core/PluginSettings.swift"),
        str(root / "Nook/Views/Settings/SettingsSnapshot.swift"),
        str(temp / "Stubs.swift"), str(temp / "Checks.swift"), "-o", str(executable),
    ], check=True)
    subprocess.run([str(executable), str(temp)], check=True)
    (temp / "CodexStubs.swift").write_text(codex_stubs)
    (temp / "CodexChecks.swift").write_text(codex_test)
    codex_executable = temp / "codex-discovery"
    subprocess.run([
        "xcrun", "swiftc", "-swift-version", "5", "-warnings-as-errors", "-O", "-parse-as-library",
        str(root / "Nook/Services/AI/CodexLink.swift"),
        str(temp / "CodexStubs.swift"), str(temp / "CodexChecks.swift"), "-o", str(codex_executable),
    ], check=True)
    subprocess.run([str(codex_executable), str(temp)], check=True)
