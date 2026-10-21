import AppKit
import Combine
import SwiftUI
import WebKit

final class LauncherFeature: ObservableObject {
    static let shared = LauncherFeature()
    @Published private(set) var history: [String: LauncherUsage] = {
        guard let data = UserDefaults.standard.data(forKey: LauncherPreferences.historyKey) else { return [:] }
        return (try? JSONDecoder().decode([String: LauncherUsage].self, from: data)) ?? [:]
    }()
    private var states: [ObjectIdentifier: LauncherState] = [:]

    static func start() {
        LauncherApplicationIndex.shared.start()
        // Resolve and persist the default once. Later assignments must not move a user's shortcut.
        let fallback = LauncherShortcut.current
        if UserDefaults.standard.data(forKey: LauncherPreferences.shortcutKey) == nil { LauncherShortcut.save(fallback) }
        ShortcutRegistry.register(id: "launcher.toggle", title: "Toggle Launcher", group: "Nook", defaultShortcut: LauncherShortcut.defaultShortcut,
                                  get: { LauncherShortcut.current }, set: { LauncherShortcut.save($0) })
        SettingsRegistry.register(id: "launcher", title: "Launcher", symbol: "magnifyingglass", tint: .orange, order: 11,
                                  keywords: ["search", "apps", "Raycast", "Spotlight", "recent", "shortcut"]) { LauncherSettingsPane() }
    }

    func state(for vm: NotchViewModel) -> LauncherState {
        states = states.filter { $0.value.vm != nil }
        let key = ObjectIdentifier(vm)
        if let state = states[key] { return state }
        let state = LauncherState(vm: vm)
        states[key] = state
        return state
    }

    static func toggle(_ controller: NotchController) {
        let vm = controller.viewModel, state = shared.state(for: controller.viewModel)
        if vm.launcherPresented { state.dismiss(restoreFocus: true); return }
        // Only one launcher owns the external selection/focus at a time, including across displays.
        for other in shared.states.values where other !== state && other.vm?.launcherPresented == true { other.dismiss() }
        state.present()
        controller.openWithKeyboard()
    }

    func record(_ id: String) {
        LauncherUsage.record(id, in: &history, at: Date().timeIntervalSince1970)
        persist()
    }
    func clearHistory() { history = [:]; persist() }
    private func persist() { UserDefaults.standard.set(try? JSONEncoder().encode(history), forKey: LauncherPreferences.historyKey) }
}

enum LauncherSystemCommand: String, CaseIterable {
    case lock, sleep, emptyTrash, darkMode, quit
    var title: String {
        switch self {
        case .lock: return "Lock Screen"
        case .sleep: return "Sleep"
        case .emptyTrash: return "Empty Trash"
        case .darkMode: return "Toggle Dark Mode"
        case .quit: return "Quit Nook"
        }
    }
    var symbol: String {
        switch self {
        case .lock: return "lock"
        case .sleep: return "moon.zzz"
        case .emptyTrash: return "trash"
        case .darkMode: return "circle.lefthalf.filled"
        case .quit: return "power"
        }
    }
    var requiresConfirmation: Bool { self == .emptyTrash || self == .quit || self == .sleep }
    var script: String {
        switch self {
        case .lock: return ""
        case .sleep: return "/usr/bin/pmset sleepnow"
        case .emptyTrash: return "/usr/bin/osascript -e 'tell application " + "\"Finder\" to empty trash'"
        case .darkMode: return "/usr/bin/osascript -e 'tell application " + "\"System Events\" to tell appearance preferences to set dark mode to not dark mode'"
        case .quit: return ""
        }
    }
}

struct LauncherEntry: Identifiable {
    enum Target { case application(LauncherApplication), nook(NotchKeyboardState.Entry), system(LauncherSystemCommand), file(String), askAI }
    let id: String
    let title: String
    let subtitle: String
    let kind: String
    let symbol: String
    let source: LauncherSource
    let target: Target
    let document: LauncherSearchDocument

    init(id: String, title: String, subtitle: String, kind: String, symbol: String, source: LauncherSource, target: Target) {
        self.id = id; self.title = title; self.subtitle = subtitle; self.kind = kind; self.symbol = symbol
        self.source = source; self.target = target
        document = LauncherSearchDocument(id: id, source: source, title: title, detail: subtitle)
    }
    var primaryTitle: String {
        switch target {
        case .application: return "Open Application"
        case .file: return "Open File"
        case .nook(let entry):
            switch entry.target { case .command: return "Run AI Command"; case .action: return "Run Action"; default: return "Open Tab" }
        case .system: return "Run Command"
        case .askAI: return "Ask AI"
        }
    }
    var secondaryTitle: String? {
        switch target {
        case .application: return "Reveal in Finder"
        case .file: return "Reveal in Finder"
        case .nook: return "Open Tab Without Running"
        default: return nil
        }
    }
}

final class LauncherState: ObservableObject, @unchecked Sendable { // main-thread confined, including all published updates
    weak var vm: NotchViewModel?
    @Published var query = "" { didSet { confirmation = nil; error = nil; actionsPresented = false; refresh() } }
    @Published private(set) var results: [LauncherEntry] = []
    @Published var selectedIndex = 0
    @Published var actionsPresented = false
    @Published var actionIndex = 0
    @Published var confirmation: String?
    @Published var error: String?
    @Published var chatQuery: String?
    @Published var answer = ""
    @Published var thinking = false
    @Published var performing = false
    private var context: AICommandContext?
    private var candidates: [LauncherEntry] = []
    private var byID: [String: LauncherEntry] = [:]
    private var bag = Set<AnyCancellable>()
    private var chatTask: Task<Void, Never>?
    private var operation = 0
    private var fileRequest = 0

    init(vm: NotchViewModel) {
        self.vm = vm
        let index = LauncherApplicationIndex.shared
        Publishers.MergeMany(index.$applications.map { _ in () }.eraseToAnyPublisher(),
                             index.$runningPaths.map { _ in () }.eraseToAnyPublisher(),
                             vm.services.commands.$commands.map { _ in () }.eraseToAnyPublisher(),
                             KeyboardActions.shared.$actions.map { _ in () }.eraseToAnyPublisher(),
                             LauncherFeature.shared.$history.map { _ in () }.eraseToAnyPublisher())
            .receive(on: RunLoop.main).sink { [weak self] in self?.rebuildIfPresented() }.store(in: &bag)
        vm.services.plugins.objectWillChange.merge(with: TabNavigationStore.shared.objectWillChange)
            .receive(on: RunLoop.main).sink { [weak self] in
                DispatchQueue.main.async { self?.rebuildIfPresented() }
            }.store(in: &bag)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.rebuildIfPresented() }.store(in: &bag)
        NotificationCenter.default.publisher(for: FileNameIndex.changed)
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.rebuildIfPresented() }.store(in: &bag)
        vm.launcherKeyHandler = { [weak self] in self?.handle($0) ?? false }
        vm.launcherEscape = { [weak self] in self?.escape() }
        vm.launcherDidClose = { [weak self] in self?.closed() }
    }

    var selected: LauncherEntry? { results.indices.contains(selectedIndex) ? results[selectedIndex] : nil }
    var canAskAI: Bool { LauncherPreferences.sources.contains(.askAI) && !LauncherQuery(query).text.isEmpty }

    func present() {
        guard let vm else { return }
        operation += 1
        context = AICommandContext.capture()
        chatTask?.cancel(); chatQuery = nil; answer = ""; thinking = false; error = nil
        vm.keyboard.isPresented = false
        vm.keyboard.engaged = true
        vm.showingSettings = false
        if vm.isOpen {
            vm.holdRect = vm.liveRect.union(vm.holdRect ?? .null)
            vm.web.emit("close", vm.tab)
        }
        query = ""
        rebuild()
        // Opening (from the header button or the shortcut) is the one animated change: the tab's content fades into the
        // launcher while the shape springs to the launcher's size, together.
        let height = targetHeight
        withAnimation(NotchViewModel.spring) {
            vm.launcherHeight = height
            vm.launcherPresented = true
        }
    }

    func closed() {
        operation += 1
        chatTask?.cancel(); chatTask = nil
        context = nil
        vm?.launcherPresented = false
        actionsPresented = false; confirmation = nil
        performing = false; thinking = false
    }

    func dismiss(restoreFocus: Bool = false) {
        let app = context?.application
        vm?.close()
        if restoreFocus, let app, !app.isTerminated { app.activate() }
    }

    private func rebuildIfPresented() { if vm?.launcherPresented == true { rebuild() } }
    private func rebuild() {
        guard let vm else { return }
        let selectedID = selected?.id
        let index = LauncherApplicationIndex.shared, sources = LauncherPreferences.sources
        var rows: [LauncherEntry] = []
        if sources.contains(.applications) {
            rows += index.applications.map { app in
                LauncherEntry(id: app.id, title: app.name, subtitle: "",
                              kind: "Application", symbol: "app", source: .applications, target: .application(app))
            }
        }
        for entry in vm.keyboard.entries {
            let source: LauncherSource, kind: String
            switch entry.target {
            case .command: source = .aiCommands; kind = "AI Command"
            case .action: source = .actions; kind = "Command"
            case .group: source = .plugins; kind = "Group"
            case .tab: source = .plugins; kind = "Plugin"
            }
            guard sources.contains(source) else { continue }
            // The kind is already on the right; drop subtitles that just repeat it ("Tab", "AI Command").
            let subtitle = ["tab", "ai command", "group", "command"].contains(entry.subtitle.lowercased()) ? "" : entry.subtitle
            rows.append(LauncherEntry(id: entry.id, title: entry.title, subtitle: subtitle, kind: kind,
                                      symbol: entry.symbol, source: source, target: .nook(entry)))
        }
        if sources.contains(.system) {
            rows += LauncherSystemCommand.allCases.map { command in
                LauncherEntry(id: "system:" + command.rawValue, title: command.title,
                              subtitle: command == .emptyTrash ? "Finder · All volumes · Confirmation required" : "macOS",
                              kind: "Command", symbol: command.symbol, source: .system, target: .system(command))
            }
        }
        candidates = rows
        byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        refresh()
        if let selectedID, let index = results.firstIndex(where: { $0.id == selectedID }) { selectedIndex = index }
    }

    private func refresh() {
        let parsed = LauncherQuery(query), now = Date().timeIntervalSince1970
        let ids = LauncherRanking.ranked(candidates.map(\.document), query: parsed, history: LauncherFeature.shared.history, now: now)
        var rows: [LauncherEntry]
        if parsed.characters.isEmpty && parsed.source == nil {
            // Empty box: what you used recently, then your AI commands and plugins — never an alphabetical app dump.
            let history = LauncherFeature.shared.history
            let used = ids.filter { history[$0] != nil }
            let usedSet = Set(used)
            let suggested = candidates.filter { !usedSet.contains($0.id) && ($0.source == .aiCommands || $0.source == .plugins) }.map(\.id)
            rows = (used + suggested).prefix(40).compactMap { byID[$0] }
        } else {
            rows = ids.prefix(60).compactMap { byID[$0] }
        }
        if canAskAI {
            rows.append(LauncherEntry(id: "askAI", title: "Ask AI: " + parsed.text, subtitle: "Send to your first saved agent, or Quick AI chat",
                                      kind: "AI", symbol: "sparkles", source: .askAI, target: .askAI))
        }
        results = rows
        selectedIndex = 0
        resize()
        fileRequest += 1
        let request = fileRequest
        if LauncherPreferences.sources.contains(.files), parsed.source == nil || parsed.source == .files {
            LauncherFileSource.search(parsed.text, client: "launcher:\(ObjectIdentifier(self))") { [weak self] result in
                guard let self, self.fileRequest == request, self.vm?.launcherPresented == true else { return }
                switch result {
                case .success(let files):
                    var rows = self.results.filter { $0.source != .files }
                    rows.insert(contentsOf: files, at: rows.firstIndex(where: { $0.source == .askAI }) ?? rows.endIndex)
                    self.results = rows; self.resize()
                case .failure(let error):
                    if parsed.source == .files { self.error = error.localizedDescription; self.resize() }
                }
            }
        }
    }

    private var pendingHeight: CGFloat?

    /// Coalesced and applied on the next run-loop turn: setting the height re-enters `resize()` through SwiftUI updates,
    /// and a nested animated change inside the first one left the black shape stuck at the old (taller) size.
    private var targetHeight: CGFloat {
        chatQuery == nil ? 62 + 24 + CGFloat(max(1, min(8, results.count))) * 44 + 42 + (error == nil ? 0 : 26) : 470
    }

    func resize() {
        guard vm != nil else { return }
        let height = targetHeight
        let scheduled = pendingHeight != nil
        pendingHeight = height
        guard !scheduled else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let vm = self.vm, let target = self.pendingHeight else { return }
            self.pendingHeight = nil
            guard vm.launcherHeight != target else { return }
            vm.holdRect = vm.liveRect.union(vm.holdRect ?? .null)
            // Typing/deleting snaps to the new size, like Raycast — no bouncing while you type.
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) { vm.launcherHeight = target }
        }
    }

    func move(_ delta: Int) {
        confirmation = nil
        if actionsPresented {
            let count = selected?.secondaryTitle == nil ? 1 : 2
            actionIndex = (actionIndex + delta + count) % count
        } else if !results.isEmpty { selectedIndex = (selectedIndex + delta + results.count) % results.count }
    }

    func escape() {
        if actionsPresented { actionsPresented = false }
        else if confirmation != nil { confirmation = nil }
        else if chatQuery != nil { operation += 1; chatTask?.cancel(); thinking = false; chatQuery = nil; error = nil; resize() }
        else if !query.isEmpty { query = "" }
        else { dismiss(restoreFocus: true) }
    }

    func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if event.keyCode == 53 { escape(); return true }
        if flags == .command && key == "k" {
            guard chatQuery == nil, selected != nil else { return true }
            actionsPresented.toggle(); actionIndex = 0; return true
        }
        if chatQuery != nil { return false }
        if event.keyCode == 125 || flags == .control && key == "n" { move(1); return true }
        if event.keyCode == 126 || flags == .control && key == "p" { move(-1); return true }
        if event.keyCode == 36 || event.keyCode == 76 {
            if !event.isARepeat, let selected { run(selected, alternate: flags.contains(.command) || actionsPresented && actionIndex == 1) }
            return true
        }
        if flags == .command, let number = Int(key), (1...9).contains(number) {
            if !event.isARepeat, results.indices.contains(number - 1) { selectedIndex = number - 1; run(results[number - 1]) }
            return true
        }
        if event.keyCode == 48 && flags.isEmpty && canAskAI { if !event.isARepeat { askAI() }; return true }
        // Editing shortcuts reach the native text field; dock shortcuts don't change tabs under this mode.
        if flags == [.command, .option] || flags.contains(.control) && event.keyCode == 48 || flags == .command && ["[", "]"].contains(key) { return true }
        return false
    }

    func run(_ entry: LauncherEntry, alternate: Bool = false) {
        guard let vm, !performing, !thinking else { return }
        actionsPresented = false
        switch entry.target {
        case .file(let path):
            FileSearchService.shared.handle(alternate ? "reveal" : "open", args: [path]) { [weak self] _, error in
                if let error { self?.error = error; self?.resize() }
                else { LauncherFeature.shared.record(entry.id); self?.dismiss() }
            }
        case .application(let app):
            dismiss()
            let url = URL(fileURLWithPath: app.path)
            if alternate { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            else {
                NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, error in
                    DispatchQueue.main.async {
                        if let error { Notifier.post(title: "Couldn't open " + app.name, body: error.localizedDescription) }
                        else { LauncherFeature.shared.record(entry.id) }
                    }
                }
            }
        case .nook(let item):
            let savedContext = context
            if alternate {
                let tab: String?
                switch item.target { case .command: tab = "commands"; case .action(let action): tab = action.pluginID; default: tab = nil }
                leaveForTab()
                if let tab { vm.select(tab) } else { vm.keyboardRun?(item, false) }
            } else {
                LauncherFeature.shared.record(entry.id)
                switch item.target {
                case .command(let id): vm.services.commands.run(id, fromNotch: true, context: savedContext)
                default: leaveForTab(); vm.keyboardRun?(item, false)
                }
            }
        case .system(let command):
            if command.requiresConfirmation && confirmation != entry.id { confirmation = entry.id; return }
            confirmation = nil
            if command == .quit { dismiss(); NSApp.terminate(nil); return }
            if command == .lock {
                dismiss()
                // macOS's Lock Screen command; the obsolete CGSession executable is absent on newer macOS.
                let source = CGEventSource(stateID: .combinedSessionState)
                for down in [true, false] {
                    let event = CGEvent(keyboardEventSource: source, virtualKey: 12, keyDown: down)
                    event?.flags = [.maskControl, .maskCommand]
                    event?.post(tap: .cghidEventTap)
                }
                LauncherFeature.shared.record(entry.id)
                return
            }
            performing = true
            let token = operation
            Shell.run(command.script, timeout: 20) { [weak self] reply in
                DispatchQueue.main.async {
                    guard let self, self.operation == token, self.vm?.launcherPresented == true else { return }
                    self.performing = false
                    if let code = reply["code"] as? Int, code != 0 {
                        self.error = (reply["stderr"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "macOS couldn't complete this command. Check Automation permissions."
                        self.resize()
                    } else { LauncherFeature.shared.record(entry.id); self.dismiss() }
                }
            }
        case .askAI: askAI()
        }
    }

    private func leaveForTab() {
        guard let vm else { return }
        vm.holdRect = vm.liveRect.union(vm.holdRect ?? .null)
        vm.launcherPresented = false
        vm.web.emit("open", vm.tab)
        context = nil
    }

    func askAI() {
        guard canAskAI, !thinking, !performing, let vm else { return }
        let prompt = LauncherQuery(query).text
        operation += 1
        let token = operation
        if let agent = AgentService.shared.agents.first, vm.isEnabled("agents"),
           let tab = vm.enabledTabs.first(where: { $0.id == "agents" }), let web = vm.web.view(for: tab) {
            // Preload while the launcher still owns focus. Wait for the plugin's handler, including cold loads.
            thinking = true
            sendToAgent(web, agentID: agent.id, prompt: prompt, token: token)
            return
        }
        startChat(prompt, token: token)
    }

    private func sendToAgent(_ web: WKWebView, agentID: String, prompt: String, token: Int, attempt: Int = 0) {
        guard operation == token, vm?.launcherPresented == true else { return }
        if web.isLoading {
            guard attempt < 100 else { thinking = false; error = "Agents did not finish loading. Try again."; resize(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak web] in
                if let web { self?.sendToAgent(web, agentID: agentID, prompt: prompt, token: token, attempt: attempt + 1) }
            }
            return
        }
        web.callAsyncJavaScript("""
                for (let attempt = 0; attempt < 100; attempt++) {
                    if (typeof window.nookLauncherAsk === 'function') return await window.nookLauncherAsk(agentID, query);
                    await new Promise(resolve => setTimeout(resolve, 50));
                }
                throw new Error('Agents did not finish loading. Open the Agents tab and try again.');
                """, arguments: ["agentID": agentID, "query": prompt], in: nil, in: .page) { [weak self] result in
                    DispatchQueue.main.async {
                        guard let self, self.operation == token else { return }
                        self.thinking = false
                        switch result {
                        case .success: self.leaveForTab(); self.vm?.select("agents")
                        case .failure(let error): self.error = error.localizedDescription; self.resize()
                        }
                    }
                }
    }

    private func startChat(_ prompt: String, token: Int) {
        chatTask?.cancel()
        chatQuery = prompt; answer = ""; thinking = true; error = nil; resize()
        chatTask = Task { @MainActor [weak self] in
            do {
                let result = try await AIBrain.complete(provider: "codex", model: "gpt-6-luna", effort: "none", prompt: prompt) { partial in
                    DispatchQueue.main.async { if self?.operation == token { self?.answer = partial } }
                }
                guard !Task.isCancelled else { return }
                self?.answer = result; self?.thinking = false
            } catch {
                guard !Task.isCancelled else { return }
                self?.error = error.localizedDescription; self?.thinking = false
            }
        }
    }
}
