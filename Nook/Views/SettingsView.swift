import SwiftUI

/// Builds only the selected pane. Native extensions use the same navigation and sizing.
struct SettingsView: View {
    let onScreensChanged: () -> Void
    @ObservedObject private var router = SettingsRouter.shared
    @ObservedObject private var features = Features.shared
    @State private var query = ""
    @State private var extensionRevision = 0

    private var builtIns: [SettingsPane] {
        SettingsPane.allCases.filter { features.paneEnabled($0.rawValue) && SettingsSearch.matches(query, in: [$0.title] + $0.keywords) }
    }

    private var extensions: [SettingsExtension] {
        _ = extensionRevision
        return SettingsRegistry.panes.filter { SettingsSearch.matches(query, in: [$0.title] + $0.keywords) }
    }

    private var visibleIDs: [String] { builtIns.map(\.rawValue) + extensions.map(\.id) }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search Settings", text: $query)
                        .textFieldStyle(.plain)
                        .accessibilityLabel("Search Settings")
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .accessibilityLabel("Clear search")
                    }
                }
                .padding(7)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
                .padding(.horizontal, 12).padding(.vertical, 10)
                List(selection: $router.pane) {
                    ForEach(builtIns) { pane in
                        SettingsSidebarRow(title: pane.title, symbol: pane.symbol, tint: pane.tint).tag(pane.rawValue)
                    }
                    if !extensions.isEmpty {
                        Section("Extensions") {
                            ForEach(extensions) { pane in
                                SettingsSidebarRow(title: pane.title, symbol: pane.symbol, tint: pane.tint).tag(pane.id)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .overlay {
                    if visibleIDs.isEmpty {
                        ContentUnavailableView.search(text: query).controlSize(.small)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 220, max: 280)
        } detail: {
            let id = router.pane ?? SettingsPane.general.rawValue
            Group {
                if !features.paneEnabled(id) {
                    FeaturesPane()
                } else if visibleIDs.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else if let pane = SettingsRegistry.panes.first(where: { $0.id == id }) {
                    pane.view().formStyle(.grouped)
                } else {
                    switch SettingsPane(rawValue: id) ?? .general {
                    case .general: GeneralPane(onScreensChanged: onScreensChanged)
                    case .tabs: TabsPane()
                    case .commands: CommandsPane()
                    case .ai: AIPane()
                    case .dictation: DictationPane()
                    case .shortcuts: ShortcutsPane()
                    case .updates: UpdatesPane()
                    case .tools: ToolsPane()
                    case .about: AboutPane()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
            .navigationTitle(SettingsRegistry.panes.first(where: { $0.id == id })?.title ?? (SettingsPane(rawValue: id) ?? .general).title)
        }
        .frame(minWidth: 980, idealWidth: 1080, minHeight: 600, idealHeight: 680)
        .onChange(of: query) { _, _ in
            if !visibleIDs.contains(router.pane ?? ""), let first = visibleIDs.first { router.pane = first }
        }
        .onChange(of: router.pane) { _, selected in
            // A CLI or plugin deep link should reveal its pane even during a sidebar search.
            if let selected, SettingsRouter.isKnown(selected), !visibleIDs.contains(selected) { query = "" }
        }
        .onReceive(NotificationCenter.default.publisher(for: .nookSettingsRegistryChanged)) { _ in
            extensionRevision += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .nookFeaturesChanged)) { _ in
            if !features.paneEnabled(router.pane ?? "") { router.pane = "features" }
        }
        .onAppear {
            if !features.paneEnabled(router.pane ?? "") { router.pane = "features" }
            if !SettingsRouter.isKnown(router.pane ?? "") { router.pane = SettingsPane.general.rawValue }
        }
    }
}

private struct SettingsSidebarRow: View {
    let title: String
    let symbol: String
    let tint: Color

    var body: some View {
        Label {
            Text(title).lineLimit(2).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 23, height: 23)
                .background(tint, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .padding(.vertical, 3)
    }
}
