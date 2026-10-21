import SwiftUI

struct ClipboardSettingsPane: View {
    @ObservedObject private var features = Features.shared
    @AppStorage(ClipPreferences.days) private var days = 30
    @AppStorage(ClipPreferences.maxItems) private var maxItems = 500
    @AppStorage(ClipPreferences.ignoredApps) private var ignoredApps = ClipPreferences.defaultIgnoredApps
    @AppStorage(ClipPreferences.folder) private var folder = ""
    @AppStorage(ClipPreferences.ocr) private var ocr = true
    @ObservedObject private var history = ClipboardHistory.shared
    @State private var confirmingClear = false

    var body: some View {
        Form {
            Section {
                Toggle("Keep clipboard history", isOn: Binding(get: { features.enabled("clipboard") }, set: { features.set("clipboard", $0) }))
                Stepper("Keep for \(days) days", value: $days, in: 1...365)
                Stepper("Maximum unpinned items: \(maxItems)", value: $maxItems, in: 50...10_000, step: 50)
            } footer: {
                Text("History stays on this Mac. Pinned items are kept until you delete them. Password-manager privacy markers are always respected.")
            }
            Section {
                TextEditor(text: $ignoredApps)
                    .font(.body)
                    .frame(minHeight: 100)
                    .accessibilityLabel("Ignored applications, one name or bundle identifier per line")
            } header: { Text("Ignored applications") } footer: {
                Text("One app name or bundle identifier per line. Changes apply to future copies; existing history remains.")
            }
            Section {
                LabeledContent("Saved clipboard items", value: "\(history.entries.count)")
                if confirmingClear {
                    Text("Clear all clipboard history, including pinned items? Nook's image copies move to Trash. Original files and screenshots stay in place.")
                    HStack {
                        Button("Cancel") { confirmingClear = false }
                        Button("Clear history", role: .destructive) { history.clear(); confirmingClear = false }
                    }
                } else {
                    Button("Clear clipboard history…", role: .destructive) { confirmingClear = true }
                }
                if let error = history.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }
        }
        .formStyle(.grouped)
    }
}
