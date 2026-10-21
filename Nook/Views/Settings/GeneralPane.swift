import SwiftUI
import ServiceManagement

// MARK: General

struct GeneralPane: View {
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
    @State private var loginError: String?
    @State private var screens = NSScreen.screens

    var body: some View {
        Form {
            Section("Notch") {
                Picker("Open the notch", selection: $openOnHover) {
                    Text("When I hover").tag(true)
                    Text("When I click").tag(false)
                }
                .pickerStyle(.segmented)
                Picker("Show the notch on", selection: $screenSetting) {
                    Text("The notched screen only").tag("")
                    Text("All screens").tag("*")
                    if !screenSetting.isEmpty, screenSetting != "*", !screens.contains(where: { $0.localizedName == screenSetting }) {
                        Text("\(screenSetting) (Disconnected)").tag(screenSetting)
                    }
                    Divider()
                    ForEach(screens, id: \.localizedName) { Text($0.localizedName).tag($0.localizedName) }
                }
                .onChange(of: screenSetting) { _, _ in onScreensChanged() }
                Toggle("Hide when an app is full screen", isOn: $hideInFullscreen)
            }
            Section {
                Toggle("Haptic feedback", isOn: $haptics)
                Toggle("Two-finger swipes", isOn: $swipes)
                Toggle("Open Shelf when dragging files onto the notch", isOn: $shelfAutoOpen)
            } header: {
                Text("Interaction")
            } footer: {
                Text("Swipe left or right to switch tabs, down on the closed notch to open it, or up on the top bar to close it.")
            }
            Section("On the closed notch") {
                Toggle("Show what's playing", isOn: $showMusic)
                Toggle("Show a running timer", isOn: $showTimer)
            }
            Section {
                Toggle("Launch at login", isOn: Binding(get: { launchAtLogin }, set: { on in
                    do {
                        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        loginError = nil
                    } catch {
                        loginError = error.localizedDescription
                    }
                    launchAtLogin = SMAppService.mainApp.status == .enabled
                }))
                if SMAppService.mainApp.status == .requiresApproval {
                    Button("Open Login Items Settings…") { SMAppService.openSystemSettingsLoginItems() }
                }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            screens = NSScreen.screens
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
