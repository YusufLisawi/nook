import SwiftUI
import ServiceManagement

// MARK: General

struct GeneralPane: View {
    let onScreensChanged: () -> Void
    @AppStorage(Prefs.openOnHover) private var openOnHover = true
    @AppStorage(Prefs.haptics) private var haptics = true
    @AppStorage(Prefs.swipes) private var swipes = true
    @AppStorage(Prefs.hideInFullscreen) private var hideInFullscreen = true
    @AppStorage(Prefs.hideFromCapture) private var hideFromCapture = true
    @AppStorage(Prefs.shelfAutoOpen) private var shelfAutoOpen = true
    @AppStorage(Prefs.showMusic) private var showMusic = true
    @AppStorage(Prefs.showTimer) private var showTimer = true
    @AppStorage(Prefs.preferredScreen) private var screenSetting = ""
    @ObservedObject private var login = SettingsSnapshots.login
    @State private var changingLogin = false
    @State private var loginError: String?
    @State private var screens = NSScreen.screens

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
                    if !screenSetting.isEmpty, screenSetting != "*", !screens.contains(where: { $0.localizedName == screenSetting }) {
                        Text("\(screenSetting) (Disconnected)").tag(screenSetting)
                    }
                    Divider()
                    ForEach(screens, id: \.self) { Text($0.localizedName).tag($0.localizedName) }
                }
                .onChange(of: screenSetting) { _, _ in onScreensChanged() }
                Toggle("Hide when an app is full screen", isOn: $hideInFullscreen)
            }
            Section {
                Toggle("Hide Nook from screen sharing and recordings", isOn: $hideFromCapture)
            } header: {
                Text("Privacy")
            } footer: {
                Text("You still see the notch and the menu bar icon. Screenshots, screen recorders and meeting screen-share (Zoom, Meet, Teams) don't.")
            }
            Section {
                Toggle("Haptic feedback", isOn: $haptics)
                Toggle("Two-finger swipes", isOn: $swipes)
                Toggle("Open Shelf when dragging files onto the notch", isOn: $shelfAutoOpen)
            } header: {
                Text("Interaction")
            } footer: {
                Text("Swipe left or right to switch tabs or deck members, down on the closed notch to open it, or up on the top bar to close it.")
            }
            Section("On the closed notch") {
                Toggle("Show what's playing", isOn: $showMusic)
                Toggle("Show a running timer", isOn: $showTimer)
            }
            Section {
                Toggle("Launch at login", isOn: Binding(get: { login.value == .enabled }, set: { on in
                    changingLogin = true
                    Task {
                        loginError = await Task.detached(priority: .userInitiated) { () -> String? in
                            do {
                                if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                                return nil
                            } catch { return error.localizedDescription }
                        }.value
                        await login.refresh(force: true)
                        changingLogin = false
                    }
                }))
                .disabled(login.value == nil || changingLogin || login.refreshing)
                if login.value == nil || changingLogin { ProgressView().controlSize(.small).accessibilityLabel("Updating login item") }
                if login.value == .requiresApproval {
                    Button("Open Login Items Settings…") { SMAppService.openSystemSettingsLoginItems() }
                }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .task { await login.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            screens = NSScreen.screens
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await login.refresh(force: true) }
        }
    }
}
