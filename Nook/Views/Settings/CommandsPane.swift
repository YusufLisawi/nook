import SwiftUI

// MARK: AI Commands

struct CommandsPane: View {
    @ObservedObject private var store = Services.shared.commands
    @State private var selection: String?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(store.commands) { command in
                        HStack {
                            Text(command.name.isEmpty ? "Untitled Command" : command.name).lineLimit(1).help(command.name)
                                .foregroundStyle(command.enabled ? .primary : .secondary)
                            Spacer()
                            if let hotkey = command.hotkey {
                                Text(hotkey.display).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .tag(command.id)
                    }
                    .onMove { store.move(from: $0, to: $1) }
                }
                .listStyle(.sidebar)
                Divider()
                HStack(spacing: 0) {
                    Button { selection = store.add().id } label: { Image(systemName: "plus").frame(width: 26, height: 22) }
                        .help("Add Command").accessibilityLabel("Add Command")
                    Button {
                        guard let id = selection else { return }
                        let index = store.commands.firstIndex { $0.id == id } ?? 0
                        store.remove(id)
                        selection = store.commands.indices.contains(index) ? store.commands[index].id : store.commands.last?.id
                    } label: { Image(systemName: "minus").frame(width: 26, height: 22) }
                        .disabled(selection == nil)
                        .help("Delete Selected Command").accessibilityLabel("Delete Selected Command")
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(4)
            }
            .frame(minWidth: 200, idealWidth: 220, maxWidth: 300)
            if let id = selection, let command = store.commands.first(where: { $0.id == id }) {
                CommandEditor(command: command, onDuplicate: { selection = $0 }).id(command.id)
                    .frame(minWidth: 450, maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label(store.commands.isEmpty ? "No AI Commands" : "Select a Command", systemImage: "wand.and.stars")
                } description: {
                    Text("Create a prompt to rewrite, translate, or work with selected text from any app.")
                } actions: {
                    Button("Create Command") { selection = store.add().id }
                }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear(perform: reconcileSelection)
        .onChange(of: store.commands.map(\.id)) { _, _ in reconcileSelection() }
    }

    private func reconcileSelection() {
        if !store.commands.contains(where: { $0.id == selection }) { selection = store.commands.first?.id }
    }
}

private struct CommandEditor: View {
    @State var command: AICommands.Command
    let onDuplicate: (String) -> Void
    @State private var insert: String?
    @ObservedObject private var store = Services.shared.commands
    private let placeholders = ["{selection}", "{clipboard}", "{app}", "{date}", "{time}"]

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $command.name)
                Toggle("Enabled", isOn: $command.enabled)
                LabeledContent("Keyboard shortcut") {
                    SettingsShortcutRecorder(item: SettingsShortcutItem(
                        id: "command:\(command.id)", title: command.name, group: "AI Commands",
                        get: { command.hotkey.map { DictationShortcut(keyCode: $0.keyCode, modifiers: $0.modifiers, display: $0.display) } },
                        set: { shortcut in
                            command.hotkey = shortcut.flatMap { key in
                                key.keyCode.map { TabHotkey(keyCode: $0, modifiers: key.modifiers, display: key.display) }
                            }
                        }
                    ))
                }
            }
            Section {
                PromptEditor(text: $command.prompt, insert: $insert)
                    .frame(minHeight: 170)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 6)], alignment: .leading, spacing: 6) {
                    ForEach(placeholders, id: \.self) { token in
                        Button { insert = token } label: {
                            Text(token).font(.system(size: 11, design: .monospaced)).fixedSize()
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                        }
                        .buttonStyle(.plain)
                        .help("Insert \(token) at the cursor")
                    }
                }
            } header: {
                Text("Prompt")
            } footer: {
                Text("{selection} is the text selected in the app you're in. The answer replaces it, is pasted after it, copied, or shown in the notch.")
                    .font(.caption)
            }
            Section("Answer") {
                Picker("Output", selection: $command.output) {
                    Text("Replace selection").tag("replace")
                    Text("Paste after selection").tag("paste")
                    Text("Copy to clipboard").tag("copy")
                    Text("Show in the notch").tag("notch")
                }
                if command.output == "replace" || command.output == "paste" {
                    Toggle("Also copy the answer to the clipboard", isOn: $command.copyToo)
                }
            }
            Section("Brain") {
                Picker("Provider", selection: $command.provider) {
                    Text("ChatGPT (Codex login)").tag("codex")
                    Text("Groq").tag("groq")
                    Text("OpenAI API").tag("openai")
                }
                .onChange(of: command.provider) { _, provider in
                    command.model = switch provider {
                    case "groq": AIBrain.groqModels[0].0
                    case "openai": "gpt-5-mini"
                    default: AIBrain.codexModels[0].0
                    }
                }
                if command.provider == "openai" {
                    TextField("Model", text: $command.model)
                } else {
                    Picker("Model", selection: $command.model) {
                        let models = command.provider == "groq" ? AIBrain.groqModels : AIBrain.codexModels
                        if !models.contains(where: { $0.0 == command.model }) { Text(command.model).tag(command.model) }
                        ForEach(command.provider == "groq" ? AIBrain.groqModels : AIBrain.codexModels, id: \.0) { Text($0.1).tag($0.0) }
                    }
                }
                Picker("Reasoning", selection: $command.effort) {
                    Text("None — fastest").tag("none")
                    Text("Low").tag("low")
                    Text("Medium").tag("medium")
                    Text("High").tag("high")
                }
            }
            Section {
                HStack {
                    Button("Duplicate") { if let copy = store.duplicate(command.id) { onDuplicate(copy.id) } }
                    Spacer()
                    Button("Delete", role: .destructive) { store.remove(command.id) }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: command) { _, updated in store.update(updated) }
        .onChange(of: store.commands) { _, commands in
            if let latest = commands.first(where: { $0.id == command.id }), latest != command { command = latest }
        }
    }
}

/// Plain-text prompt editor that can insert a placeholder at the cursor.
private struct PromptEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var insert: String?

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let view = scroll.documentView as! NSTextView
        view.delegate = context.coordinator
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.setAccessibilityLabel("Command prompt")
        view.isRichText = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.textContainerInset = NSSize(width: 4, height: 6)
        view.string = text
        scroll.drawsBackground = false
        view.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        if let token = insert {
            view.insertText(token, replacementRange: view.selectedRange())
            DispatchQueue.main.async { insert = nil }
        } else if view.string != text {
            view.string = text
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let parent: PromptEditor
        init(_ parent: PromptEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
        }
    }
}
