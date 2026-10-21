import AppKit
import SwiftUI

/// One native state per notch. The app's existing key-panel route calls handle before
/// the shared palette, so Command-K and Escape stay local to the file actions menu.
final class FileSearchTabState: ObservableObject {
    private final class Weak { weak var value: FileSearchTabState?; init(_ value: FileSearchTabState) { self.value = value } }
    private static var active: [String: Weak] = [:]
    static func handle(_ event: NSEvent, owner: String) -> Bool { active[owner]?.value?.handle(event) ?? false }
    @Published var query = "" { didSet { refresh() } }
    @Published var kind = "all" { didSet { refresh() } }
    @Published private(set) var results: [FileSearchResult] = []
    @Published var selected = 0 { didSet { confirmingPath = nil; loadPreview() } }
    @Published private(set) var gathering = true
    @Published private(set) var notice = ""
    @Published private(set) var error: String?
    @Published private(set) var preview: [String: Any] = [:]
    @Published private(set) var previewLoading = false
    @Published var actions = false
    @Published var actionIndex = 0
    @Published var confirmingPath: String?
    @Published var performing = false
    private var previewWork: DispatchWorkItem?
    private let client = UUID().uuidString
    private var request = 0
    private var resolvedRequest = 0
    private var previewVersion = 0
    private var visible = false
    private var owner = ""
    var current: FileSearchResult? { results.indices.contains(selected) ? results[selected] : nil }
    let actionList: [(String, String, String)] = [("Open", "↩", "open"), ("Show in Finder", "⌘↩", "reveal"),
        ("Quick Look", "Space", "quickLook"), ("Copy Path", "⌘C", "copyPath"), ("Copy Name", "⌥⌘C", "copyName"),
        ("Move to Trash…", "⌘⌫", "trash")]

    func start(owner: String) {
        self.owner = owner; Self.active[owner] = Weak(self); visible = true; refresh()
    }
    func stop() {
        visible = false; previewWork?.cancel()
        if Self.active[owner]?.value === self { Self.active.removeValue(forKey: owner) }
        FileSearchService.shared.cancel("native.files:" + client)
    }
    func refresh() {
        guard visible else { return }
        request += 1; let token = request
        actions = false; confirmingPath = nil; error = nil
        FileSearchService.shared.search(query, options: ["clientID": client, "requestID": String(token), "kind": kind, "limit": 100], pluginID: "native.files") { [weak self] payload in
            guard let self, self.visible, self.request == token else { return }
            self.resolvedRequest = token
            let previous = self.current?.path
            self.results = (payload["results"] as? [[String: Any]] ?? []).compactMap(FileSearchResult.init(json:))
            self.gathering = payload["gathering"] as? Bool == true || payload["indexing"] as? Bool == true
            self.notice = payload["notice"] as? String ?? ""
            self.error = payload["error"] as? String
            self.selected = self.results.firstIndex(where: { $0.path == previous }) ?? 0
        }
    }
    private func loadPreview() {
        previewWork?.cancel(); preview = [:]
        previewVersion += 1; let token = previewVersion
        guard let path = current?.path, visible else { previewLoading = false; return }
        previewLoading = true
        let work = DispatchWorkItem { [weak self] in
            FileSearchService.shared.handle("preview", args: [path]) { [weak self] value, failure in
                guard let self, self.visible, self.current?.path == path, self.previewVersion == token else { return }
                self.previewLoading = false
                self.preview = value as? [String: Any] ?? ["notice": failure ?? "No preview available."]
            }
        }
        previewWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.07, execute: work)
    }
    func move(_ delta: Int) {
        if actions { actionIndex = (actionIndex + delta + actionList.count) % actionList.count }
        else if !results.isEmpty { selected = (selected + delta + results.count) % results.count }
    }
    func perform(_ action: String, confirmed: Bool = false) {
        guard let item = current, !performing, resolvedRequest == request else { return }
        actions = false
        if action == "trash" && !confirmed { confirmingPath = item.path; return }
        if action == "trash" && confirmingPath != item.path { return }
        performing = true; error = nil
        let args: [Any] = action == "trash" ? [item.path, ["confirm": true]] : [item.path]
        FileSearchService.shared.handle(action, args: args) { [weak self] _, failure in
            guard let self else { return }
            self.performing = false; self.confirmingPath = nil; self.error = failure
            if action == "trash" && failure == nil { self.refresh() }
        }
    }
    private func handle(_ event: NSEvent) -> Bool {
        guard visible else { return false }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if event.keyCode == 53 {
            if actions { actions = false; return true }
            if confirmingPath != nil { confirmingPath = nil; return true }
            if !query.isEmpty { query = ""; return true }
            return false
        }
        if flags == .command && key == "k" {
            if current != nil { actions.toggle(); actionIndex = 0 }
            return true
        }
        if event.keyCode == 125 && flags.isEmpty { move(1); return true }
        if event.keyCode == 126 && flags.isEmpty { move(-1); return true }
        if event.keyCode == 48 && (flags.isEmpty || flags == .shift) {
            let kinds = FileSearchPreferences.kinds, index = kinds.firstIndex(of: kind) ?? 0
            kind = kinds[(index + (flags == .shift ? kinds.count - 1 : 1)) % kinds.count]; return true
        }
        if event.keyCode == 36 || event.keyCode == 76 {
            if !event.isARepeat {
                if confirmingPath != nil { perform("trash", confirmed: true) }
                else { perform(actions ? actionList[actionIndex].2 : flags.contains(.command) ? "reveal" : "open") }
            }
            return true
        }
        if event.keyCode == 49 && flags.isEmpty { if !event.isARepeat { perform("quickLook") }; return true }
        if key == "c" && (flags == .command || flags == [.command, .option]) {
            perform(flags.contains(.option) ? "copyName" : "copyPath"); return true
        }
        if event.keyCode == 51 && flags == .command { if !event.isARepeat { perform("trash") }; return true }
        return false
    }
}

struct FileSearchTab: View {
    @ObservedObject var vm: NotchViewModel
    @StateObject private var state = FileSearchTabState()
    @ObservedObject private var access = FileSearchAccess.shared
    @FocusState private var searching: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").font(.system(size: 20, weight: .light)).foregroundStyle(.secondary)
                TextField("Search files…", text: $state.query).textFieldStyle(.plain).font(.system(size: 22, weight: .medium)).tint(.white)
                    .focused($searching).keyboardInitialFocus(tab: "files")
                    .accessibilityLabel("Search files by name. Shift Space inserts a space; Space opens Quick Look.")
                if state.gathering { ProgressView().controlSize(.mini).help("Building the file index…") }
            }.padding(.horizontal, 8).frame(height: 54)
            if access.policy.needsAccess { FileSearchAccessRow() }
            HStack {
                Text(state.query.isEmpty ? "Recent" : "Results").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Picker("Kind", selection: $state.kind) {
                    ForEach(FileSearchPreferences.kinds, id: \.self) { Text($0 == "all" ? "All kinds" : $0.capitalized).tag($0) }
                }.labelsHidden().pickerStyle(.menu).controlSize(.small).fixedSize().help("Tab cycles kinds; Shift Tab goes back")
            }.padding(.horizontal, 8).frame(height: 24)
            HStack(spacing: 12) {
                resultList
                preview.frame(width: 205)
            }.frame(maxHeight: .infinity)
            if let error = state.error { status(error, color: .orange) }
            else if !state.notice.isEmpty { status(state.notice, color: .secondary) }
            footer
        }
        .foregroundStyle(.white).focusEffectDisabled()
        .onAppear { state.start(owner: vm.web.keyboardID); searching = true }
        .onDisappear { state.stop() }
        .onChange(of: vm.isOpen) { _, open in
            if open { state.start(owner: vm.web.keyboardID); searching = true } else { state.stop() }
        }
    }

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    if state.results.isEmpty {
                        VStack(spacing: 6) {
                            Image(systemName: state.gathering ? "externaldrive" : "doc.text.magnifyingglass").font(.system(size: 24)).foregroundStyle(.secondary)
                            Text(state.gathering ? "Finding your files…" : "No matching files").font(.system(size: 13, weight: .medium))
                            Text(state.gathering ? "Results appear while the first index builds." : "Try a name, ext:pdf, or added:week.")
                                .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            if state.error != nil { Button("Try Again") { state.refresh() }.buttonStyle(.plain) }
                        }.frame(maxWidth: .infinity).padding(.vertical, 40)
                    }
                    ForEach(Array(state.results.enumerated()), id: \.element.path) { index, item in
                        HStack(spacing: 10) {
                            Image(systemName: Self.symbol(item.category)).font(.system(size: 22)).foregroundStyle(.secondary).frame(width: 26)
                            VStack(alignment: .leading, spacing: 3) {
                                highlighted(item.name).font(.system(size: 13)).lineLimit(1)
                                Text(Self.shortPath(item.path)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer(minLength: 0)
                        }.padding(.horizontal, 9).frame(height: 46).contentShape(Rectangle())
                            .background(RoundedRectangle(cornerRadius: 9).fill(.white.opacity(state.selected == index ? 0.14 : 0)))
                            .onTapGesture(count: 2) { state.selected = index; state.perform("open") }
                            .onTapGesture { state.selected = index }
                            .onDrag { NSItemProvider(contentsOf: URL(fileURLWithPath: item.path, isDirectory: item.category == "folder")) ?? NSItemProvider() }
                            .accessibilityElement(children: .combine).accessibilityAddTraits(.isButton)
                            .accessibilityAddTraits(state.selected == index ? .isSelected : [])
                            .accessibilityAction { state.selected = index; state.perform("open") }
                            .id(item.path)
                    }
                }.padding(.horizontal, 1)
            }.scrollIndicators(.never)
                .onChange(of: state.current?.path) { _, path in if let path { proxy.scrollTo(path, anchor: .center) } }
        }
        .overlay(alignment: .bottomTrailing) {
            if state.actions, state.current != nil {
                VStack(spacing: 2) {
                    ForEach(Array(state.actionList.enumerated()), id: \.offset) { index, action in
                        Button { state.perform(action.2) } label: {
                            HStack { Text(action.0); Spacer(); Text(action.1).foregroundStyle(.secondary) }
                                .font(.system(size: 12)).padding(8)
                                .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(state.actionIndex == index ? 0.12 : 0)))
                        }.buttonStyle(.plain)
                    }
                }.padding(6).frame(width: 232).background(RoundedRectangle(cornerRadius: 11).fill(Color(white: 0.12)))
            }
        }
    }
    private var preview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if state.previewLoading { ProgressView().controlSize(.small).frame(maxWidth: .infinity) }
                if let item = state.current {
                    if let thumbnail = state.preview["thumbnail"] as? String,
                       let data = Data(base64Encoded: String(thumbnail.split(separator: ",", maxSplits: 1).last ?? "")), let image = NSImage(data: data) {
                        Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 134).frame(maxWidth: .infinity)
                    }
                    Text(item.name).font(.system(size: 12, weight: .medium)).lineLimit(2)
                    Text(item.kind + " · " + ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)).font(.system(size: 10)).foregroundStyle(.secondary)
                    Text("Added " + Date(timeIntervalSince1970: item.added).formatted(date: .abbreviated, time: .shortened)).font(.system(size: 10)).foregroundStyle(.secondary)
                    Text("Modified " + Date(timeIntervalSince1970: item.modified).formatted(date: .abbreviated, time: .shortened)).font(.system(size: 10)).foregroundStyle(.secondary)
                    if let text = state.preview["text"] as? String { Text(text).font(.system(size: 10, design: .monospaced)).textSelection(.enabled) }
                    if let notice = state.preview["notice"] as? String { Text(notice).font(.system(size: 11)).foregroundStyle(.secondary) }
                } else { Text("Select a file to preview").font(.system(size: 11)).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
        }.scrollIndicators(.never).background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.035)))
    }
    private var footer: some View {
        HStack(spacing: 9) {
            if state.confirmingPath != nil {
                Text("Move to Trash?").foregroundStyle(.orange)
                Button("Confirm ↩") { state.perform("trash", confirmed: true) }.buttonStyle(.plain).disabled(state.performing)
                Button("Cancel Esc") { state.confirmingPath = nil }.buttonStyle(.plain).foregroundStyle(.secondary)
            } else {
                if state.gathering { Text("Indexing…").foregroundStyle(.secondary) }
                Spacer(minLength: 0)
                Button("Open ↩") { state.perform("open") }.buttonStyle(.plain).disabled(state.current == nil)
                Text("·").foregroundStyle(.tertiary)
                Button("Actions ⌘K") { state.actions.toggle() }.buttonStyle(.plain).foregroundStyle(.secondary).disabled(state.current == nil)
            }
        }.font(.system(size: 11)).padding(.horizontal, 8).frame(height: 32)
    }
    private func status(_ text: String, color: Color) -> some View {
        Text(text).font(.system(size: 10)).foregroundStyle(color).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8)
    }
    private func highlighted(_ name: String) -> Text {
        let matches = (try? FileIndexQuery(state.query).highlights(in: name)) ?? []
        var value = AttributedString(name)
        value.foregroundColor = .white.opacity(0.75)
        for index in matches {
            let start = value.characters.index(value.characters.startIndex, offsetBy: index)
            let range = start..<value.characters.index(after: start)
            value[range].foregroundColor = .white
            value[range].font = .system(size: 13, weight: .semibold)
        }
        return Text(value)
    }
    static func symbol(_ category: String) -> String {
        ["folder": "folder.fill", "app": "app", "image": "photo", "pdf": "doc.richtext", "code": "chevron.left.forwardslash.chevron.right",
         "video": "film", "audio": "music.note", "archive": "doc.zipper" ][category] ?? "doc.text"
    }
    private static func shortPath(_ path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent, home = NSHomeDirectory()
        return FileSearchPolicy.isInside(parent, root: home) ? "~" + parent.dropFirst(home.count) : parent
    }
}

extension FileSearchResult {
    init?(json: [String: Any]) {
        guard let path = json["path"] as? String, let name = json["name"] as? String else { return nil }
        let types = ["folder": "public.folder", "app": "com.apple.application-bundle", "image": "public.image", "pdf": "com.adobe.pdf",
                     "code": "public.source-code", "video": "public.movie", "audio": "public.audio", "archive": "public.archive"]
        self.init(path: path, name: name, kind: json["kind"] as? String ?? "File", size: (json["size"] as? NSNumber)?.int64Value ?? 0,
                  modified: json["modified"] as? Double ?? 0, lastUsed: json["lastUsed"] as? Double ?? 0,
                  contentTypes: types[json["category"] as? String ?? ""].map { [$0] } ?? [], added: json["added"] as? Double ?? 0)
    }
}
