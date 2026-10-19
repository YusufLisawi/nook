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
    @State private var groqKey = Secrets.get(DictationService.Keys.groqSecret) ?? ""
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("Behaviour") {
                Toggle("Open on hover", isOn: $openOnHover)
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
                ForEach(plugins.tabs) { tab in
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
                            HotkeyRecorder(tabID: tab.id)
                        }
                    }
                }
                HStack {
                    Button("Open Plugins Folder") { NSWorkspace.shared.open(PluginRegistry.userDir) }
                    Button("Reload") { plugins.reload() }
                }
            } header: {
                Text("Tabs & plugins")
            } footer: {
                Text("Shortcuts open that tab from anywhere (press again to close). Drop a plugin folder into the Plugins folder; it shows up right away, with no rebuild.").font(.caption)
            }
            Section("Dictation") {
                SecureField("Groq API key", text: $groqKey)
                    .onChange(of: groqKey) { _, key in Secrets.set(DictationService.Keys.groqSecret, key.trimmingCharacters(in: .whitespaces)) }
                LabeledContent("Shortcuts", value: "Hold ⌃⌥ to talk · ⌥Space to toggle")
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
