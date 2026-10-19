import ServiceManagement
import SwiftUI

struct SettingsView: View {
    let controller: NotchController

    @AppStorage(Prefs.openOnHover) private var openOnHover = true
    @AppStorage(Prefs.haptics) private var haptics = true
    @AppStorage(Prefs.hideInFullscreen) private var hideInFullscreen = true
    @AppStorage(Prefs.shelfAutoOpen) private var shelfAutoOpen = true
    @AppStorage(Prefs.showMusic) private var showMusic = true
    @AppStorage(Prefs.showTimer) private var showTimer = true
    @AppStorage(Prefs.disabledTabs) private var disabledTabs = ""
    @AppStorage(Prefs.preferredScreen) private var screenName = ""
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("Behaviour") {
                Toggle("Open on hover", isOn: $openOnHover)
                Toggle("Haptic feedback", isOn: $haptics)
                Toggle("Hide when an app is full screen", isOn: $hideInFullscreen)
                Toggle("Open the shelf when dragging files onto the notch", isOn: $shelfAutoOpen)
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        if on { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
                    }
            }
            Section("Live activities") {
                Toggle("Show what's playing", isOn: $showMusic)
                Toggle("Show a running timer", isOn: $showTimer)
            }
            Section("Tabs") {
                ForEach(NotchTab.allCases) { tab in
                    Toggle(isOn: enabled(tab)) { Label(tab.title, systemImage: tab.icon) }
                }
            }
            Section("Display") {
                Picker("Screen", selection: $screenName) {
                    Text("Automatic").tag("")
                    ForEach(NSScreen.screens, id: \.localizedName) { Text($0.localizedName).tag($0.localizedName) }
                }
                .onChange(of: screenName) { _, _ in controller.rebuild() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 600)
    }

    private func enabled(_ tab: NotchTab) -> Binding<Bool> {
        Binding(
            get: { !disabledTabs.split(separator: ",").contains(Substring(tab.rawValue)) },
            set: { on in
                var off = Prefs.disabledTabSet
                if on { off.remove(tab.rawValue) } else { off.insert(tab.rawValue) }
                disabledTabs = off.sorted().joined(separator: ",")
            }
        )
    }
}
