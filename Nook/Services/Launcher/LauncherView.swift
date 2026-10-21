import SwiftUI

/// Launcher chrome is part of the notch's existing black shape, never a second panel or dock tab.
struct LauncherView: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject private var state: LauncherState
    @ObservedObject private var index = LauncherApplicationIndex.shared
    @FocusState private var searching: Bool
    @FocusState private var focusedResult: String?

    init(vm: NotchViewModel) {
        self.vm = vm
        _state = ObservedObject(wrappedValue: LauncherFeature.shared.state(for: vm))
    }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: vm.geometry.notch.height)
            if let prompt = state.chatQuery { chat(prompt) }
            else {
                search
                HStack {
                    Text(LauncherQuery(state.query).characters.isEmpty ? "Recent" : "Results")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    Spacer()
                    if index.gathering { ProgressView().controlSize(.mini).accessibilityLabel("Indexing applications") }
                }.padding(.horizontal, 18).frame(height: 24)
                results
                if let error = state.error {
                    Text(error).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).frame(height: 26)
                        .help(error).accessibilityLabel(error)
                }
                footer
            }
        }
        .foregroundStyle(.white)
        .focusEffectDisabled()
        .onAppear { searching = true }
        .onChange(of: state.chatQuery) { _, value in if value == nil { searching = true } }
        .onChange(of: state.error) { _, _ in state.resize() }
        .onChange(of: focusedResult) { _, id in
            if let index = state.results.firstIndex(where: { $0.id == id }) { state.selectedIndex = index }
        }
    }

    private var search: some View {
        HStack(spacing: 14) {
            Image(systemName: "command").font(.system(size: 21, weight: .light)).foregroundStyle(.secondary)
                .frame(width: 26)
            TextField("Search anything…", text: $state.query)
                .textFieldStyle(.plain).font(.system(size: 22, weight: .medium)).focused($searching)
                .accessibilityLabel("Search applications, AI commands, plugins and actions")
            if state.thinking { ProgressView().controlSize(.small) }
            else if state.canAskAI {
                Button { state.askAI() } label: {
                    HStack(spacing: 6) { Text("Quick AI"); keycap("⇥") }
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }.buttonStyle(.plain).help("Send query to AI (Tab)").accessibilityLabel("Quick AI, Tab")
            }
        }
        .padding(.horizontal, 18).frame(height: 62)
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if state.results.isEmpty {
                        VStack(spacing: 4) {
                            Text(index.gathering ? "Finding your applications…" : "No matching results").fontWeight(.medium)
                            Text(index.diagnostic ?? "Try an app, AI command or plugin name.")
                                .foregroundStyle(.secondary).font(.system(size: 11))
                        }.frame(maxWidth: .infinity).frame(height: 44)
                    }
                    ForEach(Array(state.results.enumerated()), id: \.element.id) { offset, entry in
                        Button { state.selectedIndex = offset; state.run(entry) } label: {
                            HStack(spacing: 10) {
                                LauncherResultIcon(entry: entry).frame(width: 28, height: 28)
                                Text(entry.title).font(.system(size: 13, weight: .medium)).lineLimit(1).layoutPriority(1)
                                Text(entry.subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                                Spacer(minLength: 4)
                                Text(entry.kind).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .padding(.horizontal, 10).frame(height: 42)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(Color.white.opacity(offset == state.selectedIndex ? 0.14 : 0)))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                        .focused($focusedResult, equals: entry.id)
                        .padding(.vertical, 1)
                        .accessibilityLabel("\(entry.title), \(entry.subtitle), \(entry.kind)")
                        .accessibilityAddTraits(offset == state.selectedIndex ? .isSelected : [])
                        .id(entry.id)
                    }
                }.padding(.horizontal, 8)
            }
            .scrollIndicators(.hidden)
            .frame(height: CGFloat(max(1, min(8, state.results.count))) * 44)
            .onChange(of: state.selected?.id) { _, id in if let id { proxy.scrollTo(id, anchor: .center) } }
        }
        .overlay(alignment: .bottomTrailing) {
            if state.actionsPresented, let entry = state.selected {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).lineLimit(1).padding(6)
                    action(entry.primaryTitle, shortcut: "↩", selected: state.actionIndex == 0) { state.run(entry) }
                    if let secondary = entry.secondaryTitle {
                        action(secondary, shortcut: "⌘↩", selected: state.actionIndex == 1) { state.run(entry, alternate: true) }
                    }
                }
                .padding(6).frame(width: 260)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.12)))
                .padding(10)
                .accessibilityElement(children: .contain).accessibilityLabel("Actions")
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button { (NSApp.delegate as? AppDelegate)?.showSettings(pane: "launcher") } label: {
                Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(.secondary)
            }.buttonStyle(.plain).help("Launcher Settings").accessibilityLabel("Launcher Settings")
            if state.confirmation != nil {
                Text("\(state.selected?.title ?? "Run command")? Press Return to confirm.")
                    .font(.system(size: 11)).foregroundStyle(.orange)
                Button("Cancel") { state.confirmation = nil }.buttonStyle(.plain).font(.system(size: 11))
            }
            Spacer(minLength: 0)
            if let entry = state.selected {
                Button { state.run(entry) } label: {
                    HStack(spacing: 8) { Text(entry.primaryTitle); keycap("↩") }
                }.buttonStyle(.plain).font(.system(size: 11, weight: .medium))
                Rectangle().fill(Color.white.opacity(0.1)).frame(width: 1, height: 14).padding(.horizontal, 3)
                Button { state.actionsPresented.toggle(); state.actionIndex = 0 } label: {
                    HStack(spacing: 6) { Text("Actions"); keycap("⌘K") }.foregroundStyle(.secondary)
                }.buttonStyle(.plain).font(.system(size: 11))
            }
        }
        .padding(.horizontal, 18).frame(height: 42)
        .background(Color.white.opacity(0.025))
    }

    private func action(_ title: String, shortcut: String, selected: Bool, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack { Text(title); Spacer(); Text(shortcut).foregroundStyle(.secondary) }
                .font(.system(size: 12)).padding(8)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(selected ? 0.12 : 0)))
        }.buttonStyle(.plain)
    }

    private func keycap(_ text: String) -> some View {
        Text(text).font(.system(size: 10)).padding(.horizontal, 4).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.06)))
    }

    private func chat(_ prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "sparkles").foregroundStyle(.orange)
                Text("Quick AI").font(.system(size: 16, weight: .semibold))
                Spacer()
                if state.thinking { ProgressView().controlSize(.small) }
            }
            Text(prompt).font(.system(size: 13, weight: .medium)).lineLimit(3)
            ScrollView {
                Text(state.answer.isEmpty ? (state.thinking ? "Thinking…" : "No response yet.") : state.answer)
                    .font(.system(size: 13)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.scrollIndicators(.hidden)
            if let error = state.error { Text(error).foregroundStyle(.orange).font(.system(size: 12)) }
            HStack {
                Button("Back to Search  Esc") { state.escape() }.buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
                Button("Copy Answer") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(state.answer, forType: .string)
                }.disabled(state.answer.isEmpty)
            }.font(.system(size: 11))
        }.padding(18).frame(height: 470)
    }
}

private struct LauncherResultIcon: View {
    let entry: LauncherEntry
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().interpolation(.high) }
            else { Image(systemName: entry.symbol).font(.system(size: 21)).foregroundStyle(entry.source == .aiCommands || entry.source == .askAI ? Color.orange : Color.white.opacity(0.7)) }
        }
        .onAppear {
            if case let .application(app) = entry.target {
                LauncherApplicationIndex.shared.icon(for: app.path) { image = $0 }
            }
        }
    }
}
