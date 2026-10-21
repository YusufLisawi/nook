import SwiftUI

struct ToolsPane: View {
    @AppStorage(ToolsInstaller.autoKey) private var auto = true
    @State private var cli = ToolsInstaller.cliInstalled
    @State private var onPath: Bool?
    @State private var installing = false
    @State private var log: [String] = []
    @State private var installedAgents: Set<String> = []
    private var agents: [(name: String, dir: URL, always: Bool)] {
        ToolsInstaller.agents.filter { $0.always || FileManager.default.fileExists(atPath: $0.dir.path) }
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("nook command") {
                    if let onPath {
                        status(cli && onPath, cli ? (onPath ? "Installed" : "Installed — not on PATH") : "Not installed")
                    } else {
                        ProgressView().controlSize(.small).accessibilityLabel("Checking command line tools")
                    }
                }
                if cli, onPath == false {
                    Button("Add ~/.local/bin to PATH") {
                        ToolsInstaller.addToPath()
                        refresh()
                    }
                    Text("Adds the command to ~/.zprofile. Open a new Terminal window to use the updated PATH.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Text(ToolsInstaller.cliLink.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
            } header: {
                Text("Command Line")
            } footer: {
                Text("Use nook new, nook open, and nook logs to build and manage plugins from Terminal.")
            }
            Section {
                ForEach(agents, id: \.name) { agent in
                    LabeledContent(agent.name) {
                        status(installedAgents.contains(agent.name), installedAgents.contains(agent.name) ? "Installed" : "Not installed")
                    }
                }
            } header: {
                Text("AI Agent Skills")
            } footer: {
                Text("The Nook skill teaches your coding agent the plugin API and UI conventions. Try “make a Nook plugin that shows my GitHub PRs.”")
            }
            Section {
                Toggle("Keep tools and skills installed and updated", isOn: $auto)
                HStack(spacing: 10) {
                    Button(cli ? "Reinstall Tools & Skills" : "Install Tools & Skills") {
                        installing = true
                        Task { @MainActor in
                            log = await Task.detached(priority: .userInitiated) { ToolsInstaller.install() }.value
                            installing = false
                            refresh()
                        }
                    }
                    .disabled(installing)
                    if installing { ProgressView().controlSize(.small) }
                }
            }
            if !log.isEmpty {
                Section("Installation Results") {
                    ForEach(Array(log.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.callout).textSelection(.enabled)
                            .foregroundStyle(line.hasPrefix("✗") ? Color.red : Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private func refresh() {
        cli = ToolsInstaller.cliInstalled
        installedAgents = Set(agents.filter { ToolsInstaller.skillInstalled(in: $0.dir) }.map(\.name))
        Task { @MainActor in
            onPath = await Task.detached(priority: .utility) { ToolsInstaller.cliOnPath }.value
        }
    }

    private func status(_ ok: Bool, _ text: String) -> some View {
        Label(text, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.circle")
            .foregroundStyle(ok ? .green : .orange).font(.callout)
            .fixedSize(horizontal: false, vertical: true)
    }
}
