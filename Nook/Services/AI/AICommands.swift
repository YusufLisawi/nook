import AppKit
import ApplicationServices

/// Raycast-style AI Commands: saved prompts with placeholders, run from a hotkey or the notch, on the current selection.
/// Output: replace the selection, paste after it, copy, or show in the notch.
final class AICommands: @unchecked Sendable { // main-thread confined
    struct Command: Codable, Identifiable {
        var id: String
        var name: String
        var icon: String
        var prompt: String
        var provider: String // codex | groq | openai
        var model: String
        var effort: String   // none | low | medium | high
        var output: String   // replace | paste | copy | notch
        var hotkey: TabHotkey?
        var enabled: Bool
    }

    static let pluginID = "commands"
    private(set) var commands: [Command] = []
    private var lastRun: [String: Any]?
    private var running: Task<Void, Never>?
    private var recordMonitor: Any?
    /// Set by AppDelegate: close every notch / open a tab on the notch under the mouse.
    var closeNotches: () -> Void = {}
    var openTab: (String) -> Void = { _ in }

    private var fileURL: URL { Services.supportDir.appendingPathComponent("ai-commands.json") }

    init() {
        if let data = try? Data(contentsOf: fileURL), let list = try? JSONDecoder().decode([Command].self, from: data) {
            commands = list
        } else {
            commands = Self.defaults
            save()
        }
    }

    // MARK: Hotkeys

    /// Called from the global event tap. Returns true if a command owns this shortcut.
    func handleShortcut(key: Int64, modifiers: CGEventFlags) -> Bool {
        guard let command = commands.first(where: { $0.enabled && $0.hotkey?.keyCode == Int(key) && $0.hotkey?.modifiers == modifiers.rawValue })
        else { return false }
        DispatchQueue.main.async { self.run(command.id, fromNotch: false) }
        return true
    }

    // MARK: Running

    func run(_ id: String, fromNotch: Bool) {
        guard let command = commands.first(where: { $0.id == id }) else { return }
        running?.cancel()
        let runID = "\(Int(Date().timeIntervalSince1970 * 1000))"
        running = Task { @MainActor in
            if fromNotch {
                // The notch had keyboard focus; give it back to the app the user was in before grabbing the selection.
                closeNotches()
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
            let clipboard = NSPasteboard.general.string(forType: .string) ?? ""
            let needsSelection = command.prompt.contains("{selection}") || command.output == "replace" || command.output == "paste"
            let selection = needsSelection ? await SelectionGrabber.selectedText() : ""
            if command.prompt.contains("{selection}"), selection.isEmpty {
                finish(runID, command, status: "error", text: "", error: "Select some text first, then run “\(command.name)”.", selection: "")
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
                switch command.output {
                case "replace": SelectionGrabber.paste(text)
                case "paste": SelectionGrabber.paste(text, after: true)
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
        let run: [String: Any] = ["runId": runID, "commandId": c.id, "name": c.name, "icon": c.icon, "status": status,
                                  "text": text, "error": error ?? NSNull(), "output": c.output, "selection": selection]
        lastRun = run
        PluginEvents.emit("commandRun", run, to: Self.pluginID)
    }

    @MainActor
    private func finish(_ runID: String, _ c: Command, status: String, text: String, error: String?, selection: String) {
        publish(runID, c, status: status, text: text, error: error, selection: selection)
        let note: (String, String, String)? = switch (status, c.output) {
        case ("error", _): ("Failed", "exclamationmark.triangle.fill", "#ff453a")
        case (_, "copy"): ("Copied", "checkmark.circle.fill", "#30d158")
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
        case "save":
            guard let dict = args.first as? [String: Any] else { return reply(nil, "Missing command") }
            upsert(dict)
            reply(payload(), nil)
        case "remove":
            commands.removeAll { $0.id == id }
            save()
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
            ["id": $0.id, "name": $0.name, "icon": $0.icon, "prompt": $0.prompt, "provider": $0.provider, "model": $0.model,
             "effort": $0.effort, "output": $0.output, "enabled": $0.enabled,
             "hotkey": $0.hotkey.map { ["display": $0.display] } ?? NSNull()]
        }
    }

    private func upsert(_ d: [String: Any]) {
        let id = (d["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString
        let existing = commands.first { $0.id == id }
        let command = Command(
            id: id,
            name: (d["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled command",
            icon: (d["icon"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "✨",
            prompt: d["prompt"] as? String ?? "",
            provider: d["provider"] as? String ?? "codex",
            model: d["model"] as? String ?? "gpt-6-luna",
            effort: d["effort"] as? String ?? "low",
            output: d["output"] as? String ?? "replace",
            hotkey: existing?.hotkey, // hotkeys change only through recordHotkey / clearHotkey
            enabled: d["enabled"] as? Bool ?? true
        )
        if let i = commands.firstIndex(where: { $0.id == id }) { commands[i] = command } else { commands.append(command) }
        save()
    }

    /// Next key combo pressed while the notch has focus becomes this command's global hotkey. Esc cancels.
    private func recordHotkey(_ id: String, reply: @escaping (Any?, String?) -> Void) {
        if let recordMonitor { NSEvent.removeMonitor(recordMonitor) }
        Services.shared.dictation.hotkeys.paused = true
        var replied = false
        let done: (Any?) -> Void = { [weak self] value in
            guard !replied else { return }
            replied = true
            if let monitor = self?.recordMonitor { NSEvent.removeMonitor(monitor) }
            self?.recordMonitor = nil
            Services.shared.dictation.hotkeys.paused = false
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
        if let data = try? JSONEncoder().encode(commands) { try? data.write(to: fileURL, options: .atomic) }
        PluginEvents.emit("commands", payload(), to: Self.pluginID)
    }

    // MARK: Starter set (like Raycast's built-ins)

    static let defaults: [Command] = {
        func c(_ name: String, _ icon: String, _ output: String, _ prompt: String) -> Command {
            Command(id: UUID().uuidString, name: name, icon: icon, prompt: prompt, provider: "codex", model: "gpt-6-luna",
                    effort: "low", output: output, hotkey: nil, enabled: true)
        }
        return [
            c("Fix Spelling and Grammar", "✍️", "replace", "Fix the spelling and grammar of the text below. Keep the language, tone, formatting and meaning. Return only the corrected text.\n\n{selection}"),
            c("Improve Writing", "🪄", "replace", "Improve the writing of the text below: clearer, tighter, same meaning and language. Return only the improved text.\n\n{selection}"),
            c("Change Tone to Professional", "💼", "replace", "Rewrite the text below in a professional, polite tone. Same language and meaning. Return only the rewritten text.\n\n{selection}"),
            c("Change Tone to Friendly", "😊", "replace", "Rewrite the text below in a warm, friendly tone. Same language and meaning. Return only the rewritten text.\n\n{selection}"),
            c("Spanish Translator", "🇪🇸", "replace", "Translate the text below to natural Spanish (Spain). Return only the translation, no quotes.\n\n{selection}"),
            c("Translate to English", "🇬🇧", "replace", "Translate the text below to natural English. Return only the translation, no quotes.\n\n{selection}"),
            c("Explain This Simply", "💡", "notch", "Explain the following in simple terms, in a few short sentences:\n\n{selection}"),
            c("Summarize", "📝", "notch", "Summarize the following in 3–5 short bullet points:\n\n{selection}"),
            c("Find Bugs in Code", "🐞", "notch", "Find bugs and risky spots in this code. Be brief: list each issue with a one-line fix.\n\n{selection}"),
        ]
    }()
}

/// Reads the selected text in the frontmost app and writes text back into it.
enum SelectionGrabber {
    /// Accessibility first (no clipboard involved); falls back to a quick ⌘C with the clipboard restored after.
    static func selectedText() async -> String {
        if let text = axSelection(), !text.isEmpty { return text }
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
    static func paste(_ text: String, after: Bool = false) {
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { restore(board, saved) }
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
