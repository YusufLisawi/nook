import SwiftUI

enum CaptureFeatureSettings {
    static func register() {
        SettingsRegistry.register(id: "screenshots", title: "Screenshots & Recordings", symbol: "photo.on.rectangle", tint: .blue, order: 45) { CaptureSettingsPane() }
    }
}

private struct CaptureSettingsPane: View {
    @ObservedObject private var access = FileSearchAccess.shared
    @AppStorage(ClipPreferences.folder) private var folder = ""
    @AppStorage(ClipPreferences.ocr) private var ocr = true
    var body: some View {
        Form {
            Section("Capture folder") {
                TextField("Folder override", text: $folder, prompt: Text("Use macOS screenshot location"))
                Text(ScreenCaptureIndex.configuredFolder().path).foregroundStyle(.secondary).textSelection(.enabled)
                LabeledContent("Folder permissions") {
                    Button("Allow access…") { access.allow() }.disabled(access.requesting)
                }
                if access.requesting { ProgressView().controlSize(.small) }
            }
            Section {
                Toggle("Recognize text in screenshots", isOn: $ocr)
            } footer: {
                Text("Originals stay in place. Text recognition runs locally. Turn off Screenshots & Recordings in Features to stop its watcher and release its index.")
            }
        }.formStyle(.grouped)
    }
}
