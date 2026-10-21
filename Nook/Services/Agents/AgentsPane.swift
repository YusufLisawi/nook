import AppKit
import SwiftUI

struct AgentsPane: View {
    @ObservedObject private var store = AgentService.shared
    @State private var selection: String?
    @State private var error: String?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(store.agents) { agent in
                        Label(agent.name, systemImage: "person.crop.circle")
                            .lineLimit(1).tag(agent.id)
                    }
                }
                .listStyle(.sidebar)
                Divider()
                HStack {
                    Button {
                        do { selection = try store.save(NookAgent()).id; error = nil }
                        catch { self.error = error.localizedDescription }
                    } label: { Image(systemName: "plus").frame(width: 26, height: 22) }
                    .help("Create an agent")
                    Spacer()
                }
                .buttonStyle(.borderless).padding(4)
            }
            .frame(width: 180)
            Divider()
            VStack(spacing: 0) {
                if let message = error ?? store.storageError {
                    Text(message).font(.callout).foregroundStyle(.red).padding()
                }
                if let agent = store.agents.first(where: { $0.id == selection }) {
                    AgentEditor(agent: agent) { selection = store.agents.first?.id }.id(agent.id)
                } else {
                    ContentUnavailableView("No agent selected", systemImage: "person.2.wave.2.fill",
                                           description: Text("Create an agent with +, then give it instructions and a working folder."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onAppear { if selection == nil { selection = store.agents.first?.id } }
    }
}

private struct AgentEditor: View {
    @State var agent: NookAgent
    var onDelete: () -> Void
    @State private var error: String?
    @State private var confirmingDelete = false
    @State private var saveTask: Task<Void, Never>?
    private let models = AgentService.models()

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $agent.name)
                LabeledContent("Working folder") {
                    HStack {
                        TextField("~", text: $agent.workingDirectory).labelsHidden()
                            .help("An absolute path or a path starting with ~")
                        Button("Choose…", action: chooseFolder)
                    }
                }
            } footer: { Text("New chats start here. Changes apply to the next turn, including resumed chats.").font(.caption) }
            Section {
                TextEditor(text: $agent.instructions)
                    .font(.body).scrollContentBackground(.hidden)
                    .frame(minHeight: 150, idealHeight: 180)
                    .accessibilityLabel("Agent instructions")
            } header: { Text("Instructions") }
            footer: { Text("Describe the agent's role, workflow and preferences. Sent as Codex developer instructions on every turn.").font(.caption) }
            Section("Model") {
                Picker("Model", selection: $agent.model) {
                    if !models.contains(where: { $0.id == agent.model }) { Text(agent.model).tag(agent.model) }
                    ForEach(models) { Text($0.name).tag($0.id) }
                }
                Picker("Reasoning", selection: $agent.effort) {
                    ForEach(NookAgent.efforts, id: \.self) { Text($0.capitalized).tag($0) }
                }
                Text("Models come from your Codex cache. Availability and reasoning levels depend on your account and model.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Full access", isOn: $agent.fullAccess)
                Label(agent.fullAccess
                      ? "This agent can run commands, change files anywhere on your Mac and use the network without asking for approval. Only use instructions and tools you trust."
                      : "Commands use Codex's workspace-write sandbox. Requests requiring approval fail because chats run without an interactive terminal.",
                      systemImage: agent.fullAccess ? "exclamationmark.triangle" : "lock.shield")
                    .font(.caption).foregroundStyle(agent.fullAccess ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: { Text("Permissions") }
            Section {
                if let error { Text(error).foregroundStyle(.red).font(.callout) }
                HStack {
                    Button("Save now", action: save).keyboardShortcut("s", modifiers: .command)
                    Spacer()
                    if confirmingDelete {
                        Text("Trash this agent's chats?").font(.caption)
                        Button("Cancel") { confirmingDelete = false }
                        Button("Delete", role: .destructive, action: remove)
                    } else {
                        Button("Delete agent…", role: .destructive) { confirmingDelete = true }
                    }
                }
            } footer: { Text("Changes save automatically. Uses your installed Codex CLI and login.").font(.caption) }
        }
        .formStyle(.grouped)
        .onChange(of: agent) { _, _ in
            saveTask?.cancel()
            saveTask = Task { @MainActor in
                do { try await Task.sleep(nanoseconds: 400_000_000) } catch { return }
                save()
            }
        }
        .onDisappear { saveTask?.cancel(); save() }
    }

    private func save() {
        // Don't recreate an agent when its editor disappears after deletion.
        guard AgentService.shared.agents.contains(where: { $0.id == agent.id }) else { return }
        do { try AgentService.shared.save(agent); error = nil }
        catch { self.error = error.localizedDescription }
    }

    private func remove() {
        do { try AgentService.shared.remove(agent.id); onDelete() }
        catch { self.error = error.localizedDescription }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: agent.directory)
        panel.prompt = "Choose working folder"
        panel.begin { response in
            if response == .OK, let url = panel.url { agent.workingDirectory = url.path }
        }
    }
}
