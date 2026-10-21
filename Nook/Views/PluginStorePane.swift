import SwiftUI

struct PluginStorePane: View {
    @ObservedObject private var store = PluginStore.shared
    @State private var query = ""
    @State private var confirmUninstall = false
    @State private var copied = false
    private let poll = Timer.publish(every: 4, on: .main, in: .common).autoconnect()

    private var filtered: [PluginStoreEntry] { store.entries.filter { $0.matches(query) } }
    private var selected: PluginStoreEntry? { store.entries.first { $0.id == store.selectedID } }

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("Search plugins", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Search plugins")
                    Button { Task { await store.refresh() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh Store")
                    .disabled(store.loading)
                }
                if store.loading { ProgressView("Refreshing Store…").controlSize(.small) }
                if let message = store.message { Text(message).font(.callout).foregroundStyle(.secondary) }
                if let error = store.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.red).textSelection(.enabled)
                }
            } footer: {
                Text("Community plugins can run commands and access your files. Review their source before installing.")
            }

            if let entry = selected {
                Section {
                    Button { store.selectedID = nil } label: {
                        Label("All plugins", systemImage: "chevron.left")
                    }
                }
                detail(entry)
            } else if let id = store.selectedID {
                Section {
                    ContentUnavailableView("Plugin unavailable", systemImage: "puzzlepiece.extension", description: Text("\(id) isn't in the current catalog. Refresh the Store or browse all plugins."))
                    Button("Browse plugins") { store.selectedID = nil }
                }
            }

            if store.selectedID == nil { catalogList }
            Section {
                Link("Browse source & contribute", destination: URL(string: "https://github.com/\(PluginStoreClient.repository)")!)
            }
        }
        .formStyle(.grouped)
        .task { await store.refresh() }
        .onReceive(poll) { _ in Task { await store.refreshInstallations() } }
        .onChange(of: query) { _, _ in store.selectedID = nil }
        .onChange(of: store.selectedID) { _, _ in confirmUninstall = false; copied = false }
    }

    private var catalogList: some View {
        Section("Plugins · \(filtered.count)") {
            if filtered.isEmpty && !store.loading {
                ContentUnavailableView(query.isEmpty ? "No plugins yet" : "No matching plugins",
                    systemImage: query.isEmpty ? "shippingbox" : "magnifyingglass",
                    description: Text(query.isEmpty ? "Community plugins will appear here once the Store is published." : "Try another name, author, or tag."))
            }
            ForEach(filtered) { entry in
                Button {
                    store.selectedID = entry.id
                    confirmUninstall = false
                    copied = false
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: entry.symbol).font(.title2).foregroundStyle(.secondary).frame(width: 30)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.name).fontWeight(.medium)
                            Text(entry.description).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer(minLength: 8)
                        if let installation = store.installations[entry.id] {
                            Text(installation.receipt == nil ? "Local copy" : (installation.receipt?.sha == entry.sha ? "Installed" : "Update"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(entry.name), \(entry.description)")
            }
        }
    }

    @ViewBuilder private func detail(_ entry: PluginStoreEntry) -> some View {
        let installed = store.installations[entry.id]
        Section(entry.name) {
            Text(entry.description).textSelection(.enabled)
            LabeledContent("Author", value: entry.author)
            LabeledContent("Version", value: entry.version)
            if let installed { LabeledContent("Installed", value: installed.version ?? "Local copy") }
            if !entry.tags.isEmpty { LabeledContent("Tags", value: entry.tags.joined(separator: ", ")) }
            if let date = ISO8601DateFormatter().date(from: entry.updatedAt) {
                LabeledContent("Updated", value: date.formatted(date: .abbreviated, time: .omitted))
            }
            ForEach(entry.screenshots, id: \.self) { path in
                if let url = entry.screenshotURL(path) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .empty: ProgressView("Loading screenshot…")
                        case .success(let image): image.resizable().scaledToFit().frame(maxHeight: 240).clipShape(RoundedRectangle(cornerRadius: 8))
                        case .failure: Label("Screenshot unavailable offline", systemImage: "photo").foregroundStyle(.secondary)
                        @unknown default: EmptyView()
                        }
                    }.accessibilityLabel("Screenshot of \(entry.name)")
                }
            }
            HStack {
                if store.busyID == entry.id {
                    ProgressView().controlSize(.small)
                    Text("Working…").foregroundStyle(.secondary)
                } else if installed == nil {
                    Button("Install") { Task { await store.install(entry, update: false) } }
                        .buttonStyle(.borderedProminent)
                } else if let receipt = installed?.receipt, receipt.sha != entry.sha {
                    Button("Update to \(entry.version)") { Task { await store.install(entry, update: true) } }
                        .buttonStyle(.borderedProminent)
                }
                if installed != nil && store.busyID != entry.id {
                    Button("Uninstall…", role: .destructive) { confirmUninstall = true }
                }
                Spacer()
                Button(copied ? "Link copied" : "Share") {
                    NSPasteboard.general.clearContents()
                    copied = NSPasteboard.general.setString("nook://install/\(entry.id)", forType: .string)
                }
            }
            .disabled(store.busyID != nil)
            if confirmUninstall {
                HStack {
                    Text("Move this plugin to Trash? Your saved data stays in Nook.").font(.callout)
                    Spacer()
                    Button("Cancel") { confirmUninstall = false }.keyboardShortcut(.cancelAction)
                    Button("Move to Trash", role: .destructive) {
                        confirmUninstall = false
                        Task { await store.uninstall(entry) }
                    }
                }.disabled(store.busyID != nil)
            }
            if installed != nil && installed?.receipt == nil {
                Text("This local copy isn't managed by the Store. Uninstall it before installing the Store version.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Link("View plugin source", destination: URL(string: "https://github.com/\(PluginStoreClient.repository)/tree/main/\(entry.path)")!)
        }
    }
}
