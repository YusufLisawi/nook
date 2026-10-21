import AppKit
import ApplicationServices

/// Raycast-style AI Commands: saved prompts with placeholders, run from a hotkey or the notch, on the current selection.
/// Output: replace the selection, paste after it, copy, or show in the notch.
final class AICommands: ObservableObject, @unchecked Sendable { // main-thread confined
    struct Command: Codable, Identifiable, Equatable {
        var id: String
        var name: String
        var prompt: String
        var provider: String // codex | groq | openai
        var model: String
        var effort: String   // none | low | medium | high
        var output: String   // replace | paste | copy | notch
        var copyToo: Bool    // also leave the answer on the clipboard (e.g. translations)
        var hotkey: TabHotkey?
        var enabled: Bool

        static func blank() -> Command {
            Command(id: UUID().uuidString, name: "New command", prompt: "{selection}", provider: "codex", model: "gpt-6-luna",
                    effort: "none", output: "replace", copyToo: false, hotkey: nil, enabled: true)
        }

        init(id: String, name: String, prompt: String, provider: String, model: String, effort: String,
             output: String, copyToo: Bool, hotkey: TabHotkey?, enabled: Bool) {
            (self.id, self.name, self.prompt, self.provider, self.model) = (id, name, prompt, provider, model)
            (self.effort, self.output, self.copyToo, self.hotkey, self.enabled) = (effort, output, copyToo, hotkey, enabled)
        }

        init(from decoder: Decoder) throws { // tolerate files from older versions
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            name = try c.decode(String.self, forKey: .name)
            prompt = try c.decode(String.self, forKey: .prompt)
            provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? "codex"
            model = try c.decodeIfPresent(String.self, forKey: .model) ?? "gpt-6-luna"
            effort = try c.decodeIfPresent(String.self, forKey: .effort) ?? "none"
            output = try c.decodeIfPresent(String.self, forKey: .output) ?? "replace"
            copyToo = try c.decodeIfPresent(Bool.self, forKey: .copyToo) ?? false
            hotkey = try c.decodeIfPresent(TabHotkey.self, forKey: .hotkey)
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        }
    }

    static let pluginID = "commands"
    @Published private(set) var commands: [Command] = []
    private var lastRun: [String: Any]?
    private var running: Task<Void, Never>?
    private var recordMonitor: Any?
    /// Set by AppDelegate: close every notch / open a tab on the notch under the mouse.
    var closeNotches: () -> Void = {}
    var openTab: (String) -> Void = { _ in }

    private var fileURL: URL { Services.supportDir.appendingPathComponent("ai-commands.json") }

    init() {
        // v2 starter set (Rewrite, Spanish translator, Explain & Translate) replaces the first, larger one once.
        let seeded = UserDefaults.standard.integer(forKey: "aiCommandsSeed") >= 2
        if seeded, let data = try? Data(contentsOf: fileURL), let list = try? JSONDecoder().decode([Command].self, from: data) {
            commands = list
        } else {
            UserDefaults.standard.set(2, forKey: "aiCommandsSeed")
            commands = Self.defaults
            save()
        }
    }

    func stop() {
        running?.cancel(); running = nil
        if let recordMonitor { NSEvent.removeMonitor(recordMonitor) }
        recordMonitor = nil; commands = []; lastRun = nil
        if Services.shared.pluginActivity?.pluginID == Self.pluginID { Services.shared.pluginActivity = nil }
    }

    // MARK: Hotkeys

    /// Called from the global event tap. Returns true if a command owns this shortcut.
    func handleShortcut(key: Int64, modifiers: CGEventFlags) -> Bool {
        guard Features.shared.enabled("commands"), let command = commands.first(where: { $0.enabled && $0.hotkey?.keyCode == Int(key) && $0.hotkey?.modifiers == modifiers.rawValue })
        else { return false }
        DispatchQueue.main.async { self.run(command.id, fromNotch: false) }
        return true
    }

    // MARK: Running

    func run(_ id: String, fromNotch: Bool, context: AICommandContext? = nil) {
        guard Features.shared.enabled("commands"), let command = commands.first(where: { $0.id == id }) else { return }
        running?.cancel()
        let runID = "\(Int(Date().timeIntervalSince1970 * 1000))"
        running = Task { @MainActor in
            if fromNotch {
                // The notch had keyboard focus; give it back to the app the user was in before grabbing the selection.
                closeNotches()
                context?.application?.activate()
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            guard !Task.isCancelled else { return }
            if let context, !context.restoreTarget() {
                finish(runID, command, status: "error", text: "", error: "The original app is unavailable. Focus it and try again.", selection: "")
                return
            }
            let app = context?.application?.localizedName ?? NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
            let clipboard = context?.clipboard ?? NSPasteboard.general.string(forType: .string) ?? ""
            let needsSelection = command.prompt.contains("{selection}") || command.output == "replace" || command.output == "paste"
            let selection: String
            if !needsSelection { selection = "" }
            else if let captured = context?.selection { selection = captured }
            else { selection = await SelectionGrabber.selectedText() }
            if command.prompt.contains("{selection}"), selection.isEmpty {
                finish(runID, command, status: "error", text: "", error: "No text to work with — select some, or put your cursor in a text box with text.", selection: "")
                return
            }
            let prompt = Self.expand(command.prompt, selection: selection, clipboard: clipboard, app: app)
            publish(runID, command, status: "running", text: "", error: nil, selection: selection)
            Services.shared.pluginActivity = PluginActivity(pluginID: Self.pluginID, text: command.name, symbol: "wand.and.stars", color: "#ff9f0a")
            if command.output == "notch" { openTab(Self.pluginID) }

            var lastEmit = Date.distantPast
            do {
                let text = try await AIBrain.complete(provider: command.provider, model: command.model, effort: command.effort, prompt: prompt) { partial in
                    guard command.output == "notch", Date().timeIntervalSince(lastEmit) > 0.08 else { return }
                    lastEmit = Date()
                    DispatchQueue.main.async { self.publish(runID, command, status: "running", text: partial, error: nil, selection: selection) }
                }
                guard !Task.isCancelled else { return }
                if let context, command.output == "replace" || command.output == "paste" {
                    context.application?.activate()
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    guard context.restoreTarget() else { throw AIBrain.Failure(message: "The original app is unavailable; the answer wasn't pasted.") }
                }
                switch command.output {
                case "replace": SelectionGrabber.paste(text, keepOnClipboard: command.copyToo)
                case "paste": SelectionGrabber.paste(text, after: true, keepOnClipboard: command.copyToo)
                case "copy":
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                default: break
                }
                finish(runID, command, status: "done", text: text, error: nil, selection: selection)
            } catch {
                finish(runID, command, status: "error", text: "", error: error.localizedDescription, selection: selection)
            }
        }
    }

    private func publish(_ runID: String, _ c: Command, status: String, text: String, error: String?, selection: String) {
        guard Features.shared.enabled("commands") else { return }
        let run: [String: Any] = ["runId": runID, "commandId": c.id, "name": c.name, "status": status,
                                  "text": text, "error": error ?? NSNull(), "output": c.output, "selection": selection]
        lastRun = run
        PluginEvents.emit("commandRun", run, to: Self.pluginID)
    }

    @MainActor
    private func finish(_ runID: String, _ c: Command, status: String, text: String, error: String?, selection: String) {
        guard Features.shared.enabled("commands"), !Task.isCancelled else { return }
        publish(runID, c, status: status, text: text, error: error, selection: selection)
        let note: (String, String, String)? = switch (status, c.output) {
        case ("error", _): ("Failed", "exclamationmark.triangle.fill", "#ff453a")
        case (_, "copy"): ("Copied", "checkmark.circle.fill", "#30d158")
        case (_, _) where c.copyToo: ("Done · copied", "checkmark.circle.fill", "#30d158")
        default: nil
        }
        if status == "error", c.output != "notch" { openTab(Self.pluginID) } // show why it failed
        if let note {
            Services.shared.pluginActivity = PluginActivity(pluginID: Self.pluginID, text: note.0, symbol: note.1, color: note.2)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if Services.shared.pluginActivity?.pluginID == Self.pluginID { Services.shared.pluginActivity = nil }
            }
        } else if Services.shared.pluginActivity?.pluginID == Self.pluginID {
            Services.shared.pluginActivity = nil
        }
    }

    static func expand(_ prompt: String, selection: String, clipboard: String, app: String) -> String {
        let now = Date()
        return prompt
            .replacingOccurrences(of: "{selection}", with: selection)
            .replacingOccurrences(of: "{clipboard}", with: clipboard)
            .replacingOccurrences(of: "{app}", with: app)
            .replacingOccurrences(of: "{date}", with: now.formatted(date: .long, time: .omitted))
            .replacingOccurrences(of: "{time}", with: now.formatted(date: .omitted, time: .shortened))
    }

    // MARK: Bridge

    func handle(_ fn: String, args: [Any], reply: @escaping (Any?, String?) -> Void) {
        let id = args.first as? String ?? ""
        switch fn {
        case "list": reply(payload(), nil)
        case "remove":
            remove(id)
            reply(payload(), nil)
        case "run":
            run(id, fromNotch: true)
            reply(NSNull(), nil)
        case "recordHotkey": recordHotkey(id, reply: reply)
        case "clearHotkey":
            if let i = commands.firstIndex(where: { $0.id == id }) { commands[i].hotkey = nil; save() }
            reply(payload(), nil)
        case "models": Task { reply(await AIBrain.providers(), nil) }
        case "lastRun": reply(lastRun ?? NSNull(), nil)
        default: reply(nil, "Unknown commands call: \(fn)")
        }
    }

    private func payload() -> [[String: Any]] {
        commands.map {
            ["id": $0.id, "name": $0.name, "prompt": $0.prompt, "provider": $0.provider, "model": $0.model,
             "effort": $0.effort, "output": $0.output, "copyToo": $0.copyToo, "enabled": $0.enabled,
             "hotkey": $0.hotkey.map { ["display": $0.display] } ?? NSNull()]
        }
    }

    // MARK: Editing (Settings → AI Commands)

    func add() -> Command {
        let command = Command.blank()
        commands.append(command)
        save()
        return command
    }

    func update(_ command: Command) {
        guard let i = commands.firstIndex(where: { $0.id == command.id }), commands[i] != command else { return }
        commands[i] = command
        save()
    }

    func duplicate(_ id: String) -> Command? {
        guard var copy = commands.first(where: { $0.id == id }) else { return nil }
        copy.id = UUID().uuidString
        copy.name += " copy"
        copy.hotkey = nil
        commands.append(copy)
        save()
        return copy
    }

    func remove(_ id: String) {
        commands.removeAll { $0.id == id }
        save()
    }

    func move(from source: IndexSet, to destination: Int) {
        commands.move(fromOffsets: source, toOffset: destination)
        save()
    }

    func setHotkey(_ id: String, _ hotkey: TabHotkey?) {
        guard let i = commands.firstIndex(where: { $0.id == id }) else { return }
        commands[i].hotkey = hotkey
        save()
    }

    /// Next key combo pressed while the notch has focus becomes this command's global hotkey. Esc cancels.
    private func recordHotkey(_ id: String, reply: @escaping (Any?, String?) -> Void) {
        if let recordMonitor { NSEvent.removeMonitor(recordMonitor) }
        Services.shared.hotkeys.paused = true
        var replied = false
        let done: (Any?) -> Void = { [weak self] value in
            guard !replied else { return }
            replied = true
            if let monitor = self?.recordMonitor { NSEvent.removeMonitor(monitor) }
            self?.recordMonitor = nil
            Services.shared.hotkeys.paused = false
            reply(value ?? NSNull(), nil)
        }
        recordMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { done(nil); return nil } // Esc
            guard let hotkey = TabHotkeys.make(from: event), let i = self.commands.firstIndex(where: { $0.id == id }) else { return nil }
            self.commands[i].hotkey = hotkey
            self.save()
            done(["display": hotkey.display])
            return nil
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { done(nil) } // give up quietly
    }

    private func save() {
        DispatchQueue.main.async { Features.shared.refreshHotkeys() }
        let snapshot = commands
        let target = fileURL
        SettingsPersistence.shared.submit(id: target.path) {
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: target, options: .atomic) }
        }
        PluginEvents.emit("commands", payload(), to: Self.pluginID)
    }

    // MARK: Starter set (like Raycast's built-ins)

    static let defaults: [Command] = {
        func c(_ name: String, _ output: String, copyToo: Bool = false, _ prompt: String) -> Command {
            Command(id: UUID().uuidString, name: name, prompt: prompt, provider: "codex", model: "gpt-6-luna",
                    effort: "none", output: output, copyToo: copyToo, hotkey: nil, enabled: true)
        }
        return [
            c("Rewrite", "replace", """
            Act as a spelling corrector, content writer, and text improver/editor. Reply only with the rewritten text and nothing else. your job is to understand what i try to mean and simplify it and make it actually well

            Strictly follow these rules:
            - Correct spelling, grammar, and punctuation errors in the given text
            - Enhance clarity and conciseness without altering the original meaning
            - Divide lengthy sentences into shorter, more readable ones
            - Eliminate unnecessary repetition while preserving important points
            - Prioritize active voice over passive voice for a more engaging tone
            - Opt for simpler, more accessible vocabulary when possible
            - ALWAYS ensure the original meaning and intention of the given text
            - ALWAYS detect and maintain the original language of the given text
            - ALWAYS maintain the existing tone of voice and style, e.g. formal, casual, polite, etc.
            - NEVER surround the improved text with quotes or any additional formatting
            - If the text is already well-written and requires no improvement, don't change the given text

            Text to improve:
            {selection}

            Improved text:
            """),
            c("Spanish translator", "replace", copyToo: true, """
            You are a spanish native speaker of castilian, your job is to translate english to castilian and vice versa,
            I will send messages in English, and you simply reply with the exact same message translated to castilian.
            Make sure to keep the same tone of voice of the initial message. Translations dont need to be literal, so try to make them sound as native as possible.
            For example, if I say:
            "Hi! My name is Pedro."
            You reply:
            "Hola! Me llamo Pedro"
            Or, if I say:
            "Don't worry about it"
            You reply:
            "No pasa nada"
            # Response instructions:
            return only the translated text, without any other text, just the translation, no dots in the end, do not think about it

            the following:
            {selection}
            """),
            c("Explain & Translate", "notch", """
            Explain the text below so I fully understand it, then translate it.

            Rules:
            - Detect its language. If it is English, translate it to Spanish (Castilian); otherwise translate it to English.
            - First a short, plain explanation (2–4 sentences) of what it means and any nuance, idiom or tone worth knowing.
            - Then a line "Translation:" followed by a natural, native-sounding translation that keeps the tone.
            - No preamble, no quotes around the text.

            Text:
            {selection}
            """),
        ]
    }()
}

/// Reads the selected text in the frontmost app and writes text back into it.
enum SelectionGrabber {
    /// Accessibility first (no clipboard involved); falls back to a quick ⌘C with the clipboard restored after.
    static func selectedText() async -> String {
        if let text = axSelection(), !text.isEmpty { return text }
        let copied = await copySelection()
        if !copied.isEmpty { return copied }
        // Nothing selected but the cursor is in a text box → use (and select) everything in it.
        return await selectAllInFocusedInput()
    }

    private static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID() else { return nil }
        return (element as! AXUIElement)
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    /// Text fields, text areas, search fields, combo boxes — and editable web content (contenteditable, inputs).
    private static func isTextInput(_ element: AXUIElement) -> Bool {
        let role = attribute(element, kAXRoleAttribute) as? String ?? ""
        if ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role) { return true }
        return attribute(element, "AXEditableAncestor") != nil
    }

    private static func selectAllInFocusedInput() async -> String {
        guard let element = focusedElement(), isTextInput(element) else { return "" }
        if let value = attribute(element, kAXValueAttribute) as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var range = CFRange(location: 0, length: (value as NSString).length)
            if let axRange = AXValueCreate(.cfRange, &range),
               AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axRange) == .success {
                return value // selected via Accessibility, so "replace" swaps exactly this
            }
        }
        press(key: 0, flags: .maskCommand) // ⌘A — only ever inside a confirmed text input
        try? await Task.sleep(nanoseconds: 80_000_000)
        return await copySelection()
    }

    private static func axSelection() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID() else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element as! AXUIElement, kAXSelectedTextAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func copySelection() async -> String {
        let board = NSPasteboard.general
        let saved = snapshot(board)
        let before = board.changeCount
        LinkCatcher.ignoreClipboardUntil = Date().addingTimeInterval(1.5) // don't save our own ⌘C as a link
        press(key: 8, flags: .maskCommand) // ⌘C
        for _ in 0..<24 where board.changeCount == before { try? await Task.sleep(nanoseconds: 25_000_000) }
        let text = board.changeCount != before ? (board.string(forType: .string) ?? "") : ""
        restore(board, saved)
        return text
    }

    /// Put text in the frontmost app by pasting, then restore the user's clipboard.
    static func paste(_ text: String, after: Bool = false, keepOnClipboard: Bool = false) {
        let board = NSPasteboard.general
        let saved = snapshot(board)
        LinkCatcher.ignoreClipboardUntil = Date().addingTimeInterval(1.5)
        board.clearContents()
        let item = NSPasteboardItem()
        item.setString(after ? "\n\n" + text : text, forType: .string)
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType")) // clipboard managers skip it
        board.writeObjects([item])
        if after { press(key: 124, flags: []) } // → collapses the selection to its end
        press(key: 9, flags: .maskCommand) // ⌘V
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            if keepOnClipboard { // leave the answer (not the "\n\n"-prefixed paste) as a normal clipboard item
                LinkCatcher.ignoreClipboardUntil = Date().addingTimeInterval(1.5)
                board.clearContents()
                board.setString(text, forType: .string)
            } else {
                restore(board, saved)
            }
        }
    }

    private static func press(key: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private static func snapshot(_ board: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (board.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
        }
    }

    private static func restore(_ board: NSPasteboard, _ items: [[NSPasteboard.PasteboardType: Data]]) {
        LinkCatcher.ignoreClipboardUntil = Date().addingTimeInterval(1.5)
        board.clearContents()
        guard !items.isEmpty else { return }
        board.writeObjects(items.map { types in
            let item = NSPasteboardItem()
            for (type, data) in types { item.setData(data, forType: type) }
            return item
        })
    }
}
