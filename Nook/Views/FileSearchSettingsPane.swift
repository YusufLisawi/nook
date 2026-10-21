import AppKit
import SwiftUI

struct FileSearchSettingsPane: View {
    @AppStorage(FileSearchPreferences.scopeKey) private var scope = "home"
    @AppStorage(FileSearchPreferences.hiddenKey) private var showHidden = false
    @AppStorage(FileSearchPreferences.excludedKey) private var excluded = ""
    @AppStorage("files.indexRoots") private var roots = ""
    @AppStorage("files.indexLibrary") private var library = false
    @AppStorage("files.indexDependencies") private var dependencies = false
    @AppStorage("files.indexPackages") private var packages = false
    @State private var status = FileNameIndex.shared.status
    @State private var ready = FileNameIndex.shared.ready

    var body: some View {
        Form {
            Section("Search") {
                Picker("Default scope", selection: $scope) {
                    Text("Home folder").tag("home")
                    Text("Developer").tag("Developer")
                    Text("Downloads").tag("Downloads")
                    Text("All configured folders").tag("all")
                }
                Toggle("Show hidden files", isOn: $showHidden)
            }
            Section("Index") {
                LabeledContent("Status", value: ready ? "\(status.count.formatted()) names" : "Building in the background…")
                if let diagnostic = status.diagnostic { Text(diagnostic).foregroundStyle(.secondary) }
                Button("Rebuild Index") { FileNameIndex.shared.start(force: true) }
                Toggle("Include Library", isOn: $library)
                Toggle("Include dependency and build folders", isOn: $dependencies)
                Toggle("Include package and app contents", isOn: $packages)
            }
            Section {
                TextEditor(text: $roots).font(.system(.body, design: .monospaced)).frame(height: 72)
                    .accessibilityLabel("Additional indexed folders, one absolute path per line")
            } header: { Text("Additional folders") } footer: {
                Text("Home is indexed by default. Add absolute paths, one per line. ~ means Home. Changes rebuild the index in the background; symlinks are not followed.")
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
                Text("One absolute folder path per line; ~ means your home folder. Folder contents are excluded too. Library, dependencies, build folders, and package contents are skipped by default.")
            }
            Section {
                Text("Names and dates stay on this Mac. Recent shows newly added or modified files first. The cached index catches up after restart; Spotlight provides temporary results during the first build. Protected folders require Files & Folders permission.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: FileNameIndex.changed)) { _ in
            status = FileNameIndex.shared.status; ready = FileNameIndex.shared.ready
        }
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
