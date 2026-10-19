import ServiceManagement
import SwiftUI

struct SettingsView: View {
    let onScreensChanged: () -> Void

    @ObservedObject private var plugins = Services.shared.plugins
    @AppStorage(Prefs.openOnHover) private var openOnHover = true
    @AppStorage(Prefs.haptics) private var haptics = true
    @AppStorage(Prefs.swipes) private var swipes = true
    @AppStorage(Prefs.hideInFullscreen) private var hideInFullscreen = true
    @AppStorage(Prefs.shelfAutoOpen) private var shelfAutoOpen = true
    @AppStorage(Prefs.showMusic) private var showMusic = true
    @AppStorage(Prefs.showTimer) private var showTimer = true
    @AppStorage(Prefs.disabledTabs) private var disabledTabs = ""
    @AppStorage(Prefs.preferredScreen) private var screenSetting = ""
    @AppStorage(DictationService.Keys.cleanup) private var cleanup = true
    @AppStorage(DictationService.Keys.sounds) private var sounds = true
    @AppStorage(DictationService.Keys.vocabulary) private var vocabulary = ""
    @AppStorage(DictationService.Keys.prompt) private var prompt = DictationService.defaultPrompt
    @AppStorage(DictationService.Keys.engine) private var engine = "chatgpt"
    @AppStorage(DictationService.Keys.micUID) private var micUID = ""
    @AppStorage(DictationService.Keys.keepAudioHours) private var keepAudioHours = 24.0
    @State private var mics = MicRecorder.microphones()
    @State private var groqKey = Secrets.get(DictationService.Keys.groqSecret) ?? ""
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("Behaviour") {
                Picker("Open the notch", selection: $openOnHover) {
                    Text("When I hover").tag(true)
                    Text("When I click").tag(false)
                }
                .pickerStyle(.segmented)
                Toggle("Haptic feedback", isOn: $haptics)
                Toggle("Trackpad swipes (two fingers: ← → tabs, ↓ open, ↑ on the top bar close)", isOn: $swipes)
                Toggle("Hide when an app is full screen", isOn: $hideInFullscreen)
                Toggle("Open the shelf when dragging files onto the notch", isOn: $shelfAutoOpen)
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        if on { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
                    }
            }
            Section("Display") {
                Picker("Show the notch on", selection: $screenSetting) {
                    Text("The notched screen only").tag("")
                    Text("All screens").tag("*")
                    Divider()
                    ForEach(NSScreen.screens, id: \.localizedName) { Text($0.localizedName).tag($0.localizedName) }
                }
                .onChange(of: screenSetting) { _, _ in onScreensChanged() }
            }
            Section("Live activities") {
                Toggle("Show what's playing", isOn: $showMusic)
                Toggle("Show a running timer", isOn: $showTimer)
            }
            Section {
                ForEach(plugins.orderedTabs) { tab in
                    Toggle(isOn: enabled(tab.id)) {
                        HStack(spacing: 8) {
                            if let icon = tab.icon, let image = NSImage(contentsOf: icon) {
                                Image(nsImage: image).resizable().frame(width: 18, height: 18)
                            } else {
                                Image(systemName: tab.symbol).frame(width: 18)
                            }
                            Text(tab.name)
                            if case .web = tab.kind { Text("plugin").font(.caption2).foregroundStyle(.secondary) }
                            Spacer()
                            CustomizeButton(tab: tab)
                            HotkeyRecorder(tabID: tab.id)
                        }
                    }
                }
                HStack {
                    Button("Open Plugins Folder") { NSWorkspace.shared.open(PluginRegistry.userDir) }
                    Button("Reload") { plugins.reload() }
                    if !plugins.customOrder.isEmpty { Button("Reset order") { plugins.resetOrder() } }
                }
            } header: {
                Text("Tabs & plugins")
            } footer: {
                Text("Drag tab icons in the notch to reorder them. Shortcuts open that tab from anywhere (press again to close). Drop a plugin folder into the Plugins folder; it shows up right away, with no rebuild.").font(.caption)
            }
            UpdatesSection()
            ToolsSection()
            Section("Dictation") {
                Picker("Transcription", selection: $engine) {
                    Text("ChatGPT (your Codex login)").tag("chatgpt")
                    Text("Groq Whisper").tag("groq")
                }
                if engine == "chatgpt" {
                    Text(OpenAITranscriber.status).font(.caption)
                        .foregroundStyle(OpenAITranscriber.readAuth() == nil ? Color.orange : Color.secondary)
                }
                Picker("Microphone", selection: $micUID) {
                    Text("System default").tag("")
                    ForEach(mics) { Text($0.name).tag($0.id) }
                }
                .onAppear { mics = MicRecorder.microphones() }
                Picker("Delete recordings after", selection: $keepAudioHours) {
                    Text("1 hour").tag(1.0)
                    Text("5 hours").tag(5.0)
                    Text("1 day").tag(24.0)
                    Text("1 week").tag(168.0)
                    Text("Never").tag(0.0)
                }
                .onChange(of: keepAudioHours) { _, _ in Services.shared.dictation.cleanupRecordings() }
                Text("Only the audio is deleted — your transcripts stay. Failed ones keep their audio for a week so you can retry.")
                    .font(.caption).foregroundStyle(.secondary)
                SecureField("Groq API key (Groq engine, AI clean-up, nook.ai)", text: $groqKey)
                    .onChange(of: groqKey) { _, key in Secrets.set(DictationService.Keys.groqSecret, key.trimmingCharacters(in: .whitespaces)) }
                LabeledContent("Hold to talk") {
                    DictationShortcutField(storageKey: DictationService.Keys.holdShortcut, fallback: .defaultHold)
                }
                LabeledContent("Press to start, press again to transcribe") {
                    DictationShortcutField(storageKey: DictationService.Keys.toggleShortcut, fallback: .defaultToggle)
                }
                Text("Click a shortcut, then press keys. Hold just modifiers (like ⌃⌥ or fn) and let go for a modifier-only shortcut. ⌫ turns it off, Esc cancels.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Clean up text with AI", isOn: $cleanup)
                Toggle("Sounds", isOn: $sounds)
                TextField("Vocabulary (one per line)", text: $vocabulary, axis: .vertical).lineLimit(2...4)
                TextField("Cleanup prompt", text: $prompt, axis: .vertical).lineLimit(3...6)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 680)
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
        if true { // every tab has at least a height
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
}

/// Settings → Updates (Sparkle).
private struct UpdatesSection: View {
    private let updater = (NSApp.delegate as? AppDelegate)?.updater.updater
    @State private var autoCheck = true
    @State private var autoInstall = false

    var body: some View {
        Section("Updates") {
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
