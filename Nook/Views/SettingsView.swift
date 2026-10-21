import ServiceManagement
import SwiftUI

/// Settings: native sidebar; only the selected pane is built, so the window opens instantly.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, tabs, commands, ai, dictation, updates, tools

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .tabs: "Tabs & Plugins"
        case .commands: "AI Commands"
        case .ai: "ChatGPT & Codex"
        case .dictation: "Dictation"
        case .updates: "Updates"
        case .tools: "Command Line"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .tabs: "square.grid.2x2.fill"
        case .commands: "wand.and.stars"
        case .ai: "sparkles"
        case .dictation: "waveform"
        case .updates: "arrow.down.circle.fill"
        case .tools: "terminal.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general: .gray
        case .tabs: .blue
        case .commands: .orange
        case .ai: .green
        case .dictation: .red
        case .updates: .indigo
        case .tools: .brown
        }
    }
}

final class SettingsRouter: ObservableObject {
    static let shared = SettingsRouter()
    /// A built-in SettingsPane rawValue or a SettingsRegistry extension id.
    @Published var pane: String? = SettingsPane.general.rawValue
}

struct SettingsView: View {
    let onScreensChanged: () -> Void
    @ObservedObject private var router = SettingsRouter.shared

    var body: some View {
        NavigationSplitView {
            List(selection: $router.pane) {
                ForEach(SettingsPane.allCases) { pane in
                    SidebarRow(title: pane.title, symbol: pane.symbol, tint: pane.tint).tag(pane.rawValue)
                }
                if !SettingsRegistry.panes.isEmpty {
                    Section("Extensions") {
                        ForEach(SettingsRegistry.panes) { ext in
                            SidebarRow(title: ext.title, symbol: ext.symbol, tint: ext.tint).tag(ext.id)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 200, max: 240)
        } detail: {
            let id = router.pane ?? SettingsPane.general.rawValue
            Group {
                if let ext = SettingsRegistry.panes.first(where: { $0.id == id }) {
                    ext.view()
                } else {
                    switch SettingsPane(rawValue: id) ?? .general {
                    case .general: GeneralPane(onScreensChanged: onScreensChanged)
                    case .tabs: TabsPane()
                    case .commands: CommandsPane()
                    case .ai: AIPane()
                    case .dictation: DictationPane()
                    case .updates: Form { UpdatesSection() }.formStyle(.grouped)
                    case .tools: Form { ToolsSection() }.formStyle(.grouped)
                    }
                }
            }
            .navigationTitle(SettingsRegistry.panes.first(where: { $0.id == id })?.title ?? (SettingsPane(rawValue: id) ?? .general).title)
        }
        .frame(minWidth: 760, idealWidth: 820, minHeight: 540, idealHeight: 600)
    }
}

struct SidebarRow: View {
    let title: String
    let symbol: String
    let tint: Color

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(tint.gradient))
        }
    }
}

// MARK: General

private struct GeneralPane: View {
    let onScreensChanged: () -> Void
    @AppStorage(Prefs.openOnHover) private var openOnHover = true
    @AppStorage(Prefs.haptics) private var haptics = true
    @AppStorage(Prefs.swipes) private var swipes = true
    @AppStorage(Prefs.hideInFullscreen) private var hideInFullscreen = true
    @AppStorage(Prefs.shelfAutoOpen) private var shelfAutoOpen = true
    @AppStorage(Prefs.showMusic) private var showMusic = true
    @AppStorage(Prefs.showTimer) private var showTimer = true
    @AppStorage(Prefs.preferredScreen) private var screenSetting = ""
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("Notch") {
                OpenNookShortcutRow()
                Picker("Open the notch", selection: $openOnHover) {
                    Text("When I hover").tag(true)
                    Text("When I click").tag(false)
                }
                .pickerStyle(.segmented)
                Picker("Show the notch on", selection: $screenSetting) {
                    Text("The notched screen only").tag("")
                    Text("All screens").tag("*")
                    Divider()
                    ForEach(NSScreen.screens, id: \.localizedName) { Text($0.localizedName).tag($0.localizedName) }
                }
                .onChange(of: screenSetting) { _, _ in onScreensChanged() }
                Toggle("Hide when an app is full screen", isOn: $hideInFullscreen)
            }
            Section("Feel") {
                Toggle("Haptic feedback", isOn: $haptics)
                Toggle("Two-finger swipes", isOn: $swipes)
                Text("← → switch tabs · ↓ on the closed notch opens it · ↑ on the top bar closes it")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Open the shelf when dragging files onto the notch", isOn: $shelfAutoOpen)
            }
            Section("On the closed notch") {
                Toggle("Show what's playing", isOn: $showMusic)
                Toggle("Show a running timer", isOn: $showTimer)
            }
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        if on { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
                    }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Tabs & Plugins

private struct TabsPane: View {
    @ObservedObject private var plugins = Services.shared.plugins
    @AppStorage(Prefs.disabledTabs) private var disabledTabs = ""

    var body: some View {
        Form {
            Section {
                ForEach(plugins.orderedTabs) { tab in
                    HStack(spacing: 10) {
                        if let icon = tab.icon, let image = NSImage(contentsOf: icon) {
                            Image(nsImage: image).resizable().frame(width: 18, height: 18)
                        } else {
                            Image(systemName: tab.symbol).frame(width: 18).foregroundStyle(.secondary)
                        }
                        Text(tab.name)
                        if case .web = tab.kind { Text("plugin").font(.caption2).foregroundStyle(.tertiary) }
                        Spacer()
                        HotkeyRecorder(tabID: tab.id)
                        CustomizeButton(tab: tab)
                        Toggle("", isOn: enabled(tab.id)).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                }
            } footer: {
                Text("Drag tab icons in the notch to reorder. A shortcut opens that tab from anywhere (press again to close).")
                    .font(.caption)
            }
            Section {
                HStack {
                    Button("Open Plugins Folder") { NSWorkspace.shared.open(PluginRegistry.userDir) }
                    Button("Reload") { plugins.reload() }
                    if !plugins.customOrder.isEmpty { Button("Reset Order") { plugins.resetOrder() } }
                }
            } footer: {
                Text("Drop a plugin folder into the Plugins folder — it shows up right away, no rebuild.").font(.caption)
            }
        }
        .formStyle(.grouped)
    }

    private func enabled(_ id: String) -> Binding<Bool> {
        Binding(
            get: { !disabledTabs.split(separator: ",").contains(Substring(id)) },
            set: { on in
                var off = Prefs.disabledTabSet
                if on { off.remove(id) } else { off.insert(id) }
                disabledTabs = off.sorted().joined(separator: ",")
            }
        )
    }
}

/// Opens a plugin's options (and Edit code / Revert) in a popover.
private struct CustomizeButton: View {
    let tab: TabItem
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: { Image(systemName: "slider.horizontal.3") }
            .buttonStyle(.borderless)
            .help("Customize \(tab.name)")
            .popover(isPresented: $open, arrowEdge: .trailing) {
                PluginSettingsForm(tab: tab) { open = false }
                    .padding(16)
                    .frame(width: 340)
            }
    }
}

// MARK: AI Commands

private struct CommandsPane: View {
    @ObservedObject private var store = Services.shared.commands
    @State private var selection: String?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(store.commands) { command in
                        HStack {
                            Text(command.name).lineLimit(1)
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
                    Button {
                        guard let id = selection else { return }
                        let index = store.commands.firstIndex { $0.id == id } ?? 0
                        store.remove(id)
                        selection = store.commands.indices.contains(index) ? store.commands[index].id : store.commands.last?.id
                    } label: { Image(systemName: "minus").frame(width: 26, height: 22) }
                        .disabled(selection == nil)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(4)
            }
            .frame(width: 210)
            Divider()
            if let id = selection, let command = store.commands.first(where: { $0.id == id }) {
                CommandEditor(command: command).id(command.id)
            } else {
                ContentUnavailableView("No command selected", systemImage: "wand.and.stars",
                                       description: Text("Pick one on the left, or press + to create one."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { if selection == nil { selection = store.commands.first?.id } }
    }
}

private struct CommandEditor: View {
    @State var command: AICommands.Command
    @State private var insert: String?
    private var store: AICommands { Services.shared.commands }
    private let placeholders = ["{selection}", "{clipboard}", "{app}", "{date}", "{time}"]

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $command.name)
                Toggle("Enabled", isOn: $command.enabled)
                LabeledContent("Hotkey") { CommandHotkeyField(command: $command) }
            }
            Section {
                PromptEditor(text: $command.prompt, insert: $insert)
                    .frame(minHeight: 170)
                HStack(spacing: 5) {
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
                    Button("Duplicate") { _ = store.duplicate(command.id) }
                    Spacer()
                    Button("Delete", role: .destructive) { store.remove(command.id) }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: command) { _, updated in store.update(updated) }
    }
}

/// Click, then press a shortcut; it works from any app. ⌫ clears, Esc cancels.
private struct CommandHotkeyField: View {
    @Binding var command: AICommands.Command
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button(recording ? "Press keys…" : (command.hotkey?.display ?? "Record Hotkey")) { recording ? stop() : start() }
                .font(.system(size: 12, design: .rounded))
            if command.hotkey != nil, !recording {
                Button { command.hotkey = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        Services.shared.dictation.hotkeys.paused = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch event.keyCode {
            case 53: stop()
            case 51, 117: command.hotkey = nil; stop()
            default:
                guard let hotkey = TabHotkeys.make(from: event) else { return nil }
                command.hotkey = hotkey
                stop()
            }
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        Services.shared.dictation.hotkeys.paused = false
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

// MARK: ChatGPT & Codex

private struct AIPane: View {
    @State private var state = CodexLink.state()
    @State private var path = CodexLink.cliPath()
    @State private var testing = false
    @State private var testResult: (Bool, Double, String)?
    @State private var groqKey = Secrets.get(DictationService.Keys.groqSecret) ?? ""
    @State private var openAIKey = Secrets.get(AIBrain.openAISecret) ?? ""
    private let poll = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: icon).font(.system(size: 26)).foregroundStyle(color)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(color.opacity(0.15)))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(headline).font(.headline)
                        Text(detail).font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            Section {
                LabeledContent("Codex") {
                    if let path {
                        Label(path.replacingOccurrences(of: NSHomeDirectory(), with: "~"), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green).font(.callout)
                    } else {
                        Button("Install Codex") { CodexLink.install() }
                    }
                }
                LabeledContent("ChatGPT account") {
                    switch state {
                    case let .ready(email):
                        Label(email ?? "Signed in", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
                    case .apiKey:
                        Button("Sign in with ChatGPT instead") { CodexLink.signIn() }
                    default:
                        Button("Sign in with ChatGPT") { CodexLink.signIn() }.disabled(path == nil)
                    }
                }
                LabeledContent("Connection") {
                    HStack(spacing: 8) {
                        if testing { ProgressView().controlSize(.small) }
                        if let testResult {
                            Text(testResult.0 ? String(format: "Works · %.1fs", testResult.1) : testResult.2)
                                .font(.callout).foregroundStyle(testResult.0 ? .green : .red).lineLimit(2)
                        }
                        Button("Test") {
                            testing = true
                            Task {
                                testResult = await CodexLink.test()
                                testing = false
                            }
                        }
                        .disabled(testing || !isReady)
                    }
                }
            } header: {
                Text("Setup")
            } footer: {
                Text("Nook uses your ChatGPT subscription the same way the Codex app does — through your Codex login. No API key, no extra cost. Install and sign-in open Terminal for one command.")
                    .font(.caption)
            }
            Section {
                SecureField("Groq API key", text: $groqKey)
                    .onChange(of: groqKey) { _, key in Secrets.set(DictationService.Keys.groqSecret, key.trimmingCharacters(in: .whitespaces)) }
                SecureField("OpenAI API key", text: $openAIKey)
                    .onChange(of: openAIKey) { _, key in Secrets.set(AIBrain.openAISecret, key.trimmingCharacters(in: .whitespaces)) }
            } header: {
                Text("Other providers (optional)")
            } footer: {
                Text("Pick them per command in AI Commands. Groq also powers dictation clean-up and nook.ai in plugins.").font(.caption)
            }
        }
        .formStyle(.grouped)
        .onReceive(poll) { _ in // picks up `codex login` finishing in Terminal
            let next = CodexLink.state()
            if next != state { state = next; CodexLink.refresh(); path = CodexLink.cliPath() }
        }
    }

    private var isReady: Bool { if case .ready = state { true } else { false } }
    private var icon: String { isReady ? "checkmark.seal.fill" : "link.badge.plus" }
    private var color: Color { isReady ? .green : .orange }
    private var headline: String {
        switch state {
        case .ready: "Connected to ChatGPT"
        case .apiKey: "Codex uses an API key"
        case .signedOut: "Codex is installed — sign in"
        case .notInstalled: "Connect your ChatGPT subscription"
        }
    }
    private var detail: String {
        switch state {
        case .ready: "AI Commands and dictation run on your subscription."
        case .apiKey: "Sign in with ChatGPT to use your subscription instead of paid API calls."
        case .signedOut: "One click opens Terminal with `codex login`."
        case .notInstalled: "Install Codex, then sign in with your ChatGPT account."
        }
    }
}

// MARK: Dictation

private struct DictationPane: View {
    @AppStorage(DictationService.Keys.cleanup) private var cleanup = true
    @AppStorage(DictationService.Keys.sounds) private var sounds = true
    @AppStorage(DictationService.Keys.vocabulary) private var vocabulary = ""
    @AppStorage(DictationService.Keys.prompt) private var prompt = DictationService.defaultPrompt
    @AppStorage(DictationService.Keys.engine) private var engine = "chatgpt"
    @AppStorage(DictationService.Keys.micUID) private var micUID = ""
    @AppStorage(DictationService.Keys.keepAudioHours) private var keepAudioHours = 24.0
    @State private var mics = MicRecorder.microphones()

    var body: some View {
        Form {
            Section("Shortcuts") {
                LabeledContent("Hold to talk") {
                    DictationShortcutField(storageKey: DictationService.Keys.holdShortcut, fallback: .defaultHold)
                }
                LabeledContent("Press to start, again to transcribe") {
                    DictationShortcutField(storageKey: DictationService.Keys.toggleShortcut, fallback: .defaultToggle)
                }
            }
            Section("Recording") {
                Picker("Microphone", selection: $micUID) {
                    Text("System default").tag("")
                    ForEach(mics) { Text($0.name).tag($0.id) }
                }
                Picker("Transcription", selection: $engine) {
                    Text("ChatGPT (Codex login)").tag("chatgpt")
                    Text("Groq Whisper").tag("groq")
                }
                Picker("Delete recordings after", selection: $keepAudioHours) {
                    Text("1 hour").tag(1.0)
                    Text("5 hours").tag(5.0)
                    Text("1 day").tag(24.0)
                    Text("1 week").tag(168.0)
                    Text("Never").tag(0.0)
                }
                .onChange(of: keepAudioHours) { _, _ in Services.shared.dictation.cleanupRecordings() }
                Toggle("Sounds", isOn: $sounds)
            }
            Section {
                Toggle("Clean up text with AI (Groq)", isOn: $cleanup)
                TextField("Vocabulary (one per line)", text: $vocabulary, axis: .vertical).lineLimit(2...4)
                TextField("Clean-up prompt", text: $prompt, axis: .vertical).lineLimit(3...8)
            } header: {
                Text("Clean-up")
            } footer: {
                Text("Transcripts stay; only audio is deleted. Failed recordings are kept a week so Retry works.").font(.caption)
            }
        }
        .formStyle(.grouped)
        .onAppear { mics = MicRecorder.microphones() }
    }
}

// MARK: Updates

private struct UpdatesSection: View {
    private let updater = (NSApp.delegate as? AppDelegate)?.updater.updater
    @State private var autoCheck = true
    @State private var autoInstall = false

    var body: some View {
        Section {
            LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")
            Toggle("Check for updates automatically", isOn: $autoCheck)
                .onChange(of: autoCheck) { _, on in updater?.automaticallyChecksForUpdates = on }
            Toggle("Download and install updates automatically", isOn: $autoInstall)
                .onChange(of: autoInstall) { _, on in updater?.automaticallyDownloadsUpdates = on }
                .disabled(!autoCheck)
            Button("Check Now") { updater?.checkForUpdates() }
        }
        .onAppear {
            autoCheck = updater?.automaticallyChecksForUpdates ?? true
            autoInstall = updater?.automaticallyDownloadsUpdates ?? false
        }
    }
}
