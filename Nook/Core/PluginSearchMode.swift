import AppKit
import Combine
import SwiftUI

/// The panel owns focus, sizing and navigation; plugin helpers own searchable content.
final class LauncherFeature {
    static let shared = LauncherFeature()
    private var states: [ObjectIdentifier: LauncherState] = [:]
    func state(for vm: NotchViewModel) -> LauncherState {
        states = states.filter { $0.value.vm != nil }
        let key = ObjectIdentifier(vm)
        if let value = states[key] { return value }
        let value = LauncherState(vm: vm); states[key] = value; return value
    }
    static func reconfigure() {
        if !Features.shared.enabled("launcher") { stop() }
    }
    static func stop() { shared.states.values.forEach { $0.dismiss() }; shared.states.removeAll(); LauncherAnswers.disable() }
    static func toggle(_ controller: NotchController) {
        guard Features.shared.enabled("launcher") else { return }
        let state = shared.state(for: controller.viewModel)
        if controller.viewModel.launcherPresented { state.dismiss(); return }
        shared.states.values.filter { $0 !== state }.forEach { $0.dismiss() }
        state.present(); controller.openWithKeyboard()
    }
}

struct LauncherEntry: Identifiable {
    let id: String
    let localID: String
    let provider: PluginSearch.Provider
    let title: String
    let subtitle: String
    let kind: String
    let symbol: String
    let confirm: Bool
    let keyEquivalent: String
}

final class LauncherState: ObservableObject {
    weak var vm: NotchViewModel?
    @Published var query = "" { didSet { refresh() } }
    @Published var results: [LauncherEntry] = []
    @Published var smartAnswer: LauncherAnswer?
    @Published var selectedIndex = 0
    @Published var error: String?
    @Published var loading = false
    @Published var performing = false
    @Published var actionsPresented = false
    @Published var actionIndex = 0
    @Published var confirmation: String?
    private var generation = 0
    private var answerRequest: LauncherAnswerRequest?
    private var context: AICommandContext?
    private var answerOwner: String?
    private var bag = Set<AnyCancellable>()
    init(vm: NotchViewModel) {
        self.vm = vm
        vm.launcherKeyHandler = { [weak self] in self?.handle($0) ?? false }
        vm.launcherEscape = { [weak self] in self?.escape() }
        vm.launcherDidClose = { [weak self] in self?.closed() }
        NotificationCenter.default.publisher(for: .nookPluginEvent).sink { [weak self] note in
            guard let event = note.userInfo?["event"] as? String, ["native:searchChanged", "native:ready"].contains(event), self?.vm?.launcherPresented == true else { return }
            self?.refresh()
        }.store(in: &bag)
    }
    var selected: LauncherEntry? { results.indices.contains(selectedIndex) ? results[selectedIndex] : nil }
    var answerSelected: Bool { selectedIndex == -1 && smartAnswer != nil }
    func present() {
        guard let vm else { return }
        context = AICommandContext.capture()
        vm.keyboard.isPresented = false; vm.keyboard.engaged = true; vm.showingSettings = false
        if vm.isOpen { vm.web.emit("close", vm.tab) }
        withAnimation(NotchViewModel.spring) { vm.launcherHeight = 370; vm.launcherPresented = true }
        query = ""
    }
    func closed() {
        for provider in PluginSearch.providers.values { PluginSearch.queue.cancel(prefix: provider.pluginID + "/" + provider.method + "/" + String(describing: ObjectIdentifier(self))) }
        generation += 1; answerRequest?.cancel(); answerRequest = nil; loading = false; results = []; smartAnswer = nil; context = nil; vm?.launcherPresented = false }
    func dismiss(restoreFocus: Bool = false) { let app = context?.application; vm?.close(); closed(); if restoreFocus { app?.activate() } }
    func refresh() {
        guard let vm, vm.launcherPresented else { return }
        generation += 1; let current = generation
        error = nil; confirmation = nil; smartAnswer = nil; answerOwner = nil; actionsPresented = false; results = []; selectedIndex = 0
        let providers = Array(PluginSearch.providers.sorted { $0.key < $1.key }.prefix(16).map(\.value))
        loading = !providers.isEmpty
        var remaining = providers.count
        let items = vm.keyboard.entries.map { entry -> [String: Any] in
            let source: String
            switch entry.target { case .command: source = "aiCommands"; case .action: source = "actions"; default: source = "plugins" }
            return ["id": entry.id, "title": entry.title, "subtitle": entry.subtitle, "symbol": entry.symbol, "kind": "Nook", "source": source]
        }
        answerRequest?.cancel()
        if Features.shared.enabled("smartAnswers"), !query.isEmpty {
            answerRequest = LauncherAnswers.shared.request(query, invalidated: { [weak self] in
                DispatchQueue.main.async { if self?.generation == current { self?.refresh() } }
            }) { [weak self] answer in
                guard let self, self.generation == current, let answer, self.smartAnswer == nil else { return }
                self.smartAnswer = answer; self.answerOwner = answer.pluginID; self.selectedIndex = -1
            }
        }
        for provider in providers {
            let text = String(query.prefix(512))
            let queueKey = provider.pluginID + "/" + provider.method + "/" + String(describing: ObjectIdentifier(self))
            PluginSearch.queue.submit(queueKey) { done in
            PluginEngine.shared.webCall(id: provider.pluginID, method: "native.call", args: [provider.method, ["query": text, "items": Array(items.prefix(2000))]], vm: vm) { [weak self] value, failure in
                defer { done() }
                guard let self, self.generation == current, self.vm?.launcherPresented == true else { return }
                remaining -= 1; self.loading = remaining > 0
                if let failure { self.error = failure; return }
                let object = value as? [String: Any] ?? [:]
                let rows = object["items"] as? [[String: Any]] ?? []
                self.results += rows.prefix(100).compactMap { row in
                    guard let id = row["id"] as? String, !id.isEmpty, let title = row["title"] as? String else { return nil }
                    return LauncherEntry(id: provider.pluginID + ":" + id, localID: String(id.prefix(4096)), provider: provider, title: String(title.prefix(200)), subtitle: String((row["subtitle"] as? String ?? "").prefix(500)), kind: String((row["kind"] as? String ?? "").prefix(80)), symbol: row["symbol"] as? String ?? "puzzlepiece.extension", confirm: row["confirm"] as? Bool ?? false, keyEquivalent: String((row["keyEquivalent"] as? String ?? "").prefix(16)))
                }
                if self.smartAnswer == nil, let row = object["answer"] as? [String: Any], let answer = LauncherAnswer.decode(row) { self.smartAnswer = answer; self.answerOwner = provider.pluginID; self.selectedIndex = -1 }
            }
            }
        }
    }
    func move(_ delta: Int) {
        if actionsPresented {
            let count = answerSelected ? max(1, smartAnswer?.actions.count ?? 0) : 2
            actionIndex = (actionIndex + delta + count) % count; return
        }
        let first = smartAnswer == nil ? 0 : -1, count = results.count + (smartAnswer == nil ? 0 : 1)
        if count > 0 { selectedIndex = first + (selectedIndex - first + delta + count) % count }
    }
    func escape() { if actionsPresented { actionsPresented = false } else if confirmation != nil { confirmation = nil } else if !query.isEmpty { query = "" } else { dismiss(restoreFocus: true) } }
    func handle(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 { escape(); return true }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if event.keyCode == 125 || flags == .control && key == "n" { move(1); return true }
        if event.keyCode == 126 || flags == .control && key == "p" { move(-1); return true }
        if flags == .command, let number = Int(key), (1...9).contains(number), results.indices.contains(number - 1) {
            if !event.isARepeat { selectedIndex = number - 1; run(results[number - 1]) }; return true
        }
        if event.keyCode == 48, flags.isEmpty, let row = results.first(where: { $0.keyEquivalent == "tab" }) {
            if !event.isARepeat { run(row) }; return true
        }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "k" { actionsPresented.toggle(); actionIndex = 0; return true }
        if [36, 76].contains(event.keyCode) { if !event.isARepeat { if answerSelected { if actionsPresented, let answer = smartAnswer, answer.actions.indices.contains(actionIndex) { runAnswerAction(answer.actions[actionIndex]) } else { runAnswer(paste: event.modifierFlags.contains(.command)) } } else if let selected { run(selected, alternate: event.modifierFlags.contains(.command) || actionsPresented && actionIndex == 1) } }; return true }
        return false
    }
    func run(_ entry: LauncherEntry, alternate: Bool = false) {
        guard !performing else { return }
        if entry.confirm && confirmation != entry.id { confirmation = entry.id; return }
        performing = true
        PluginEngine.shared.webCall(id: entry.provider.pluginID, method: "native.call", args: [entry.provider.actionMethod, ["id": entry.localID, "alternate": alternate, "confirmed": confirmation == entry.id]], vm: vm) { [weak self] value, failure in
            guard let self else { return }; self.performing = false
            if let failure { self.error = failure; return }
            if let row = (value as? [String: Any])?["answer"] as? [String: Any], let answer = LauncherAnswer.decode(row) {
                self.smartAnswer = answer; self.answerOwner = entry.provider.pluginID; self.selectedIndex = -1; return
            }
            if let id = (value as? [String: Any])?["hostItemID"] as? String, let item = self.vm?.keyboard.entries.first(where: { $0.id == id }) {
                self.vm?.launcherPresented = false; self.vm?.keyboardRun?(item, alternate)
            } else { self.dismiss() }
        }
    }
    func runAnswerAction(_ action: LauncherAnswer.Action) {
        switch action.value {
        case .copy(let value): runAnswer(value: value)
        case .open(let url):
            guard let owner = answerOwner else { return }
            PluginEngine.shared.hostCall(id: owner, method: "network.open", params: ["url": url.absoluteString], vm: vm) { [weak self] _, failure in if let failure { self?.error = failure } }
        }
    }

    func runAnswer(paste: Bool = false, value: String? = nil) {
        guard let answer = smartAnswer, answer.isAvailable || value != nil, let owner = answerOwner else { return }
        let text = value ?? answer.copyValue
        PluginEngine.shared.hostCall(id: owner, method: paste ? "selection.paste" : "clipboard.write", params: ["text": text], vm: vm) { [weak self] _, failure in
            if let failure { self?.error = failure } else { self?.dismiss(restoreFocus: true) }
        }
    }
}

struct LauncherView: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject private var state: LauncherState
    @FocusState private var focused: Bool
    @FocusState private var focusedResult: String?
    init(vm: NotchViewModel) { self.vm = vm; state = LauncherFeature.shared.state(for: vm) }
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search…", text: $state.query).textFieldStyle(.plain).font(.system(size: 20)).focused($focused)
                if state.loading { ProgressView().controlSize(.small) }
            }.padding(12)
            Divider().overlay(.white.opacity(0.08))
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 4) {
                        if let answer = state.smartAnswer {
                            Button { state.selectedIndex = -1; state.runAnswer() } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(answer.section).font(.caption).foregroundStyle(.secondary)
                                HStack {
                                    Text(answer.expression).foregroundStyle(.secondary); Spacer()
                                    if let color = answer.swatch { RoundedRectangle(cornerRadius: 5).fill(Color(red: color.red, green: color.green, blue: color.blue)).frame(width: 24, height: 24).accessibilityLabel("Color preview") }
                                    Text(answer.result).font(.title2)
                                }
                                if !answer.leftBadge.isEmpty || !answer.rightBadge.isEmpty { HStack { Text(answer.leftBadge); Spacer(); Text(answer.rightBadge) }.font(.caption).foregroundStyle(.secondary) }
                                if let note = answer.note { Text(note).font(.caption).foregroundStyle(.secondary) }
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 9).fill(.white.opacity(state.answerSelected ? 0.12 : 0.045)))
                            }.buttonStyle(.plain).focused($focusedResult, equals: "__answer").id(-1)
                        }
                        ForEach(Array(state.results.enumerated()), id: \.element.id) { index, row in
                            Button { state.selectedIndex = index; state.run(row) } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: row.symbol).frame(width: 24)
                                    VStack(alignment: .leading, spacing: 2) { Text(row.title).lineLimit(1); if !row.subtitle.isEmpty { Text(row.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) } }
                                    Spacer(); Text(state.confirmation == row.id ? "Confirm ↵" : row.kind).font(.caption).foregroundStyle(.secondary)
                                }.padding(9).contentShape(Rectangle()).background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(state.selectedIndex == index ? 0.12 : 0)))
                            }.buttonStyle(.plain).focused($focusedResult, equals: row.id).id(index)
                        }
                        if state.results.isEmpty && state.smartAnswer == nil && !state.loading { Text(state.query.isEmpty ? "Type to search enabled providers." : "No results").foregroundStyle(.secondary).padding(24) }
                    }
                }.onChange(of: state.selectedIndex) { _, value in proxy.scrollTo(value) }
            }
            if let error = state.error { HStack { Text(error).font(.caption).foregroundStyle(.red); Spacer(); Button("Retry") { state.refresh() } } }
            if state.actionsPresented {
                HStack {
                    if state.answerSelected, let answer = state.smartAnswer {
                        ForEach(Array(answer.actions.enumerated()), id: \.offset) { index, action in Button(action.title) { state.runAnswerAction(action) }.foregroundStyle(index == state.actionIndex ? .primary : .secondary) }
                    }
                    else if let row = state.selected { Button("Open") { state.run(row) }; Button("Alternate") { state.run(row, alternate: true) } }
                    Spacer()
                }
            }
            HStack { Text("↑↓ Choose   ↵ Open   ⌘↵ Alternate   ⌘K Actions"); Spacer(); Text("Esc Close") }.font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(.horizontal, 14).padding(.bottom, 8).onAppear { focused = true }.onChange(of: focusedResult) { _, id in
            if id == "__answer" { state.selectedIndex = -1 }
            else if let index = state.results.firstIndex(where: { $0.id == id }) { state.selectedIndex = index }
        }
    }
}
