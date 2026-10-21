import AppKit
import SwiftUI

struct FileSearchSettingsPane: View {
    @AppStorage(FileSearchPreferences.scopeKey) private var scope = "home"
    @AppStorage(FileSearchPreferences.hiddenKey) private var showHidden = false
    @AppStorage(FileSearchPreferences.excludedKey) private var excluded = ""

    var body: some View {
        Form {
            Section("Search") {
                Picker("Default scope", selection: $scope) {
                    Text("Home folder").tag("home")
                    Text("Developer").tag("Developer")
                    Text("Downloads").tag("Downloads")
                    Text("All indexed locations").tag("all")
                }
                Toggle("Show hidden files", isOn: $showHidden)
            }
            Section {
                TextEditor(text: $excluded)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 100, maxHeight: 160)
                    .accessibilityLabel("Excluded folders, one absolute path per line")
                Button("Add Folder…", action: chooseFolder)
            } header: {
                Text("Excluded folders")
            } footer: {
                Text("One absolute folder path per line; ~ means your home folder. Folder contents are excluded too. node_modules, .git, and Library caches, logs, and developer data are always excluded.")
            }
            Section {
                Text("File Search uses the Spotlight index. Unindexed, protected, and Spotlight Privacy locations won't appear. An empty search shows recently used files. Preferences apply to open searches immediately.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Exclude"
        panel.begin { response in
            guard response == .OK else { return }
            let paths = excluded.components(separatedBy: .newlines).filter { !$0.isEmpty }
            excluded = Array(Set(paths + panel.urls.map(\.path))).sorted().joined(separator: "\n")
        }
    }
}
