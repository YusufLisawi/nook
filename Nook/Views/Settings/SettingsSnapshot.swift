import SwiftUI
import ServiceManagement

/// A pane can appear immediately with its last result while slow discovery stays off the main thread.
/// Concurrent refreshes share one task; unsuccessful discoveries are cached just like successful ones.
@MainActor final class SettingsSnapshot<Value>: ObservableObject {
    @Published private(set) var value: Value?
    @Published private(set) var refreshing = false
    private let load: () -> Value
    private let lifetime: TimeInterval
    private var refreshedAt: Date?
    private var inFlight: Task<Void, Never>?
    private var refreshAgain = false

    init(lifetime: TimeInterval = 30, load: @escaping () -> Value) {
        self.lifetime = lifetime
        self.load = load
    }

    func refresh(force: Bool = false) async {
        if let inFlight {
            // An installation or device change during discovery must not leave a stale result cached.
            if force { refreshAgain = true }
            await inFlight.value
            return
        }
        if !force, let refreshedAt, Date().timeIntervalSince(refreshedAt) < lifetime { return }
        refreshing = true
        let task = Task { @MainActor in
            repeat {
                self.refreshAgain = false
                let load = self.load
                self.value = await Task.detached(priority: .utility) { load() }.value
                self.refreshedAt = Date()
            } while self.refreshAgain
            self.inFlight = nil
            self.refreshing = false
        }
        inFlight = task
        await task.value
    }
}

struct SettingsCodexStatus {
    let state: CodexLink.State
    let path: String?
}

struct SettingsToolsStatus {
    let cli: Bool
    let onPath: Bool
    let agents: [(name: String, installed: Bool)]
}

@MainActor enum SettingsSnapshots {
    static let codex = SettingsSnapshot {
        CodexLink.refresh()
        return SettingsCodexStatus(state: CodexLink.state(), path: CodexLink.cliPath())
    }
    static let tools = SettingsSnapshot {
        SettingsToolsStatus(cli: ToolsInstaller.cliInstalled, onPath: ToolsInstaller.cliOnPath,
                            agents: ToolsInstaller.agents
                                .filter { $0.always || FileManager.default.fileExists(atPath: $0.dir.path) }
                                .map { ($0.name, ToolsInstaller.skillInstalled(in: $0.dir)) })
    }
    static let microphones = SettingsSnapshot { MicRecorder.microphones() }
    static let login = SettingsSnapshot { SMAppService.mainApp.status }
}
