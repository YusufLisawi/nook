import Combine
import Sparkle
import SwiftUI

/// Observe Sparkle so both update buttons follow checks already running elsewhere in the app.
final class SettingsUpdateState: ObservableObject {
    static let shared = SettingsUpdateState()
    @Published private(set) var canCheck = false
    private var observation: AnyCancellable?
    var updater: SPUUpdater? { (NSApp.delegate as? AppDelegate)?.updater.updater }

    private init() {
        observation = updater?.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.canCheck = $0 }
    }
}

struct SettingsCheckForUpdatesButton: View {
    @ObservedObject private var state = SettingsUpdateState.shared

    var body: some View {
        Button("Check for Updates…") { state.updater?.checkForUpdates() }
            .disabled(!state.canCheck)
    }
}

struct UpdatesPane: View {
    @ObservedObject private var state = SettingsUpdateState.shared
    @State private var autoCheck = true
    @State private var autoInstall = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Version", value: NookVersion.description)
                SettingsCheckForUpdatesButton()
            } header: {
                Text("Software Update")
            } footer: {
                Text("Updates are signed and notarized. Nook checks for new releases daily when automatic checks are enabled.")
            }
            Section("Automatic Updates") {
                Toggle("Check for updates automatically", isOn: $autoCheck)
                    .onChange(of: autoCheck) { _, on in state.updater?.automaticallyChecksForUpdates = on }
                Toggle("Download and install updates automatically", isOn: $autoInstall)
                    .onChange(of: autoInstall) { _, on in state.updater?.automaticallyDownloadsUpdates = on }
                    .disabled(!autoCheck)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            autoCheck = state.updater?.automaticallyChecksForUpdates ?? true
            autoInstall = state.updater?.automaticallyDownloadsUpdates ?? false
        }
    }
}

enum NookVersion {
    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown" }
    static var build: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown" }
    static var description: String { "\(version) (\(build))" }
}
