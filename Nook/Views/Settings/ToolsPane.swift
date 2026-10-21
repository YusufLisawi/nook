import SwiftUI

struct ToolsPane: View {
    @AppStorage(ToolsInstaller.autoKey) private var auto = true
    @ObservedObject private var tools = SettingsSnapshots.tools
    @State private var installing = false
    @State private var log: [String] = []
    private var cli: Bool { tools.value?.cli ?? false }

    var body: some View {
        Form {
            Section {
                LabeledContent("nook command") {
                    if let snapshot = tools.value {
                        status(cli && snapshot.onPath, cli ? (snapshot.onPath ? "Installed" : "Installed — not on PATH") : "Not installed")
                    } else {
                        ProgressView().controlSize(.small).accessibilityLabel("Checking command line tools")
                    }
                }
                if cli, tools.value?.onPath == false {
                    Button("Add ~/.local/bin to PATH") {
                        installing = true
                        Task {
                            await Task.detached(priority: .userInitiated) { ToolsInstaller.addToPath() }.value
                            await tools.refresh(force: true)
                            installing = false
                        }
                    }
                    .disabled(installing)
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
                ForEach(tools.value?.agents ?? [], id: \.name) { agent in
                    LabeledContent(agent.name) {
                        status(agent.installed, agent.installed ? "Installed" : "Not installed")
                    }
                }
                if tools.value == nil { ProgressView("Checking installed skills…").controlSize(.small) }
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
                            await tools.refresh(force: true)
                            installing = false
                        }
                    }
                    .disabled(installing || tools.value == nil || tools.refreshing)
                    if installing { ProgressView().controlSize(.small) }
                    Spacer(minLength: 0)
                    Button("Refresh Status") { Task { await tools.refresh(force: true) } }
                        .disabled(installing || tools.refreshing)
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
        .task { await tools.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await tools.refresh(force: true) }
        }
    }

    private func status(_ ok: Bool, _ text: String) -> some View {
        Label(text, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.circle")
            .foregroundStyle(ok ? .green : .orange).font(.callout)
            .fixedSize(horizontal: false, vertical: true)
    }
}
