import AppKit
import ApplicationServices

/// Raycast-style AI Commands: saved prompts with placeholders, run from a hotkey or the notch, on the current selection.
/// Output: replace the selection, paste after it, copy, or show in the notch.
final class AICommands: ObservableObject, @unchecked Sendable {  // main-thread confined
  struct Command: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var prompt: String
    var provider: String  // codex | groq | openai
    var model: String
    var effort: String  // none | low | medium | high
    var output: String  // replace | paste | copy | notch
    var copyToo: Bool  // also leave the answer on the clipboard (e.g. translations)
    var hotkey: TabHotkey?
    var enabled: Bool

    static func blank() -> Command {
      Command(
        id: UUID().uuidString, name: "New command", prompt: "{selection}", provider: "codex",
        model: "gpt-6-luna",
        effort: "none", output: "replace", copyToo: false, hotkey: nil, enabled: true)
    }

    init(
      id: String, name: String, prompt: String, provider: String, model: String, effort: String,
      output: String, copyToo: Bool, hotkey: TabHotkey?, enabled: Bool
    ) {
      (self.id, self.name, self.prompt, self.provider, self.model) = (
        id, name, prompt, provider, model
      )
      (self.effort, self.output, self.copyToo, self.hotkey, self.enabled) = (
        effort, output, copyToo, hotkey, enabled
      )
    }

    init(from decoder: Decoder) throws {  // tolerate files from older versions
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

    if let data = try? Data(contentsOf: fileURL),
      let list = try? JSONDecoder().decode([Command].self, from: data)
    {
      commands = list
    } else {
      PluginDefaults.standard.set(2, forKey: "aiCommandsSeed")
      commands = Self.defaults
      save()
    }
  }

  func stop() {
    running?.cancel()
    running = nil
    if let recordMonitor { NSEvent.removeMonitor(recordMonitor) }
    recordMonitor = nil
    commands = []
    lastRun = nil
    if Services.shared.pluginActivity?.pluginID == Self.pluginID {
      Services.shared.pluginActivity = nil
    }
  }

  // MARK: Hotkeys

  /// Called from the global event tap. Returns true if a command owns this shortcut.
  func handleShortcut(key: Int64, modifiers: CGEventFlags) -> Bool {
    guard Features.shared.enabled("commands"),
      let command = commands.first(where: {
        $0.enabled && $0.hotkey?.keyCode == Int(key) && $0.hotkey?.modifiers == modifiers.rawValue
      })
    else { return false }
    DispatchQueue.main.async { self.run(command.id, fromNotch: false) }
    return true
  }

  // MARK: Running

  func run(_ id: String, fromNotch: Bool, context: String? = nil) {
    guard Features.shared.enabled("commands"), let command = commands.first(where: { $0.id == id })
    else { return }
    running?.cancel()
    PluginRuntime.beginWork()
    let runID = "\(Int(Date().timeIntervalSince1970 * 1000))"
    running = Task { @MainActor in
      defer { PluginRuntime.endWork() }
      if fromNotch {
        // The notch had keyboard focus; give it back to the app the user was in before grabbing the selection.
        closeNotches()

        try? await Task.sleep(nanoseconds: 250_000_000)
      }
      guard !Task.isCancelled else { return }
      let metadata =
        (try? PluginRuntime.sync("selection.capture", ["context": context ?? ""])) as? [String: Any]
        ?? [:]
      let app = metadata["app"] as? String ?? ""
      let clipboard = metadata["clipboard"] as? String ?? ""
      let needsSelection =
        command.prompt.contains("{selection}") || command.output == "replace"
        || command.output == "paste"
      let selection: String
      if !needsSelection {
        selection = ""
      } else {
        do {
          selection =
            (try PluginRuntime.sync("selection.get", ["context": context ?? ""])) as? String ?? ""
        } catch {
          finish(
            runID, command, status: "error", text: "", error: error.localizedDescription,
            selection: "")
          return
        }
      }
      if command.prompt.contains("{selection}"), selection.isEmpty {
        finish(
          runID, command, status: "error", text: "",
          error: "No text to work with — select some, or put your cursor in a text box with text.",
          selection: "")
        return
      }
      let prompt = Self.expand(command.prompt, selection: selection, clipboard: clipboard, app: app)
      publish(runID, command, status: "running", text: "", error: nil, selection: selection)
      Services.shared.pluginActivity = PluginActivity(
        pluginID: Self.pluginID, text: command.name, symbol: "wand.and.stars", color: "#ff9f0a")
      if command.output == "notch" { openTab(Self.pluginID) }

      var lastEmit = Date.distantPast
      do {
        let text = try await AIBrain.complete(
          provider: command.provider, model: command.model, effort: command.effort, prompt: prompt
        ) { partial in
          guard command.output == "notch", Date().timeIntervalSince(lastEmit) > 0.08 else { return }
          lastEmit = Date()
          DispatchQueue.main.async {
            self.publish(
              runID, command, status: "running", text: partial, error: nil, selection: selection)
          }
        }
        guard !Task.isCancelled else { return }
        switch command.output {
        case "replace":
          _ = try PluginRuntime.sync(
            "selection.paste",
            ["text": text, "keepOnClipboard": command.copyToo, "context": context ?? ""])
        case "paste":
          _ = try PluginRuntime.sync(
            "selection.paste",
            [
              "text": text, "after": true, "keepOnClipboard": command.copyToo,
              "context": context ?? "",
            ])
        case "copy":
          PluginRuntime.host("clipboard.write", ["text": text])
        default: break
        }
        finish(runID, command, status: "done", text: text, error: nil, selection: selection)
      } catch {
        finish(
          runID, command, status: "error", text: "", error: error.localizedDescription,
          selection: selection)
      }
    }
  }

  private func publish(
    _ runID: String, _ c: Command, status: String, text: String, error: String?, selection: String
  ) {
    guard Features.shared.enabled("commands") else { return }
    let run: [String: Any] = [
      "runId": runID, "commandId": c.id, "name": c.name, "status": status,
      "text": text, "error": error ?? NSNull(), "output": c.output, "selection": selection,
    ]
    lastRun = run
    PluginEvents.emit("commandRun", run, to: Self.pluginID)
  }

  @MainActor
  private func finish(
    _ runID: String, _ c: Command, status: String, text: String, error: String?, selection: String
  ) {
    guard Features.shared.enabled("commands"), !Task.isCancelled else { return }
    publish(runID, c, status: status, text: text, error: error, selection: selection)
    let note: (String, String, String)? =
      switch (status, c.output) {
      case ("error", _): ("Failed", "exclamationmark.triangle.fill", "#ff453a")
      case (_, "copy"): ("Copied", "checkmark.circle.fill", "#30d158")
      case (_, _) where c.copyToo: ("Done · copied", "checkmark.circle.fill", "#30d158")
      default: nil
      }
    if status == "error", c.output != "notch" { openTab(Self.pluginID) }  // show why it failed
    if let note {
      Services.shared.pluginActivity = PluginActivity(
        pluginID: Self.pluginID, text: note.0, symbol: note.1, color: note.2)
      DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
        if Services.shared.pluginActivity?.pluginID == Self.pluginID {
          Services.shared.pluginActivity = nil
        }
      }
    } else if Services.shared.pluginActivity?.pluginID == Self.pluginID {
      Services.shared.pluginActivity = nil
    }
  }

  static func expand(_ prompt: String, selection: String, clipboard: String, app: String) -> String
  {
    let now = Date()
    return
      prompt
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
    case "move":
      if let index = commands.firstIndex(where: { $0.id == id }),
        let delta = args.dropFirst().first as? Int
      {
        let destination = max(0, min(commands.count - 1, index + delta))
        let command = commands.remove(at: index)
        commands.insert(command, at: destination)
        save()
      }
      reply(payload(), nil)
    case "save":
      do {
        let value = try JSONDecoder().decode(
          Command.self, from: JSONSerialization.data(withJSONObject: args.first ?? [:]))
        if commands.contains(where: { $0.id == value.id }) {
          update(value)
        } else {
          commands.append(value)
          save()
        }
        reply(payload(), nil)
      } catch { reply(nil, error.localizedDescription) }
    case "list": reply(payload(), nil)
    case "remove":
      remove(id)
      reply(payload(), nil)
    case "run":
      run(id, fromNotch: true, context: PluginRuntime.context)
      reply(NSNull(), nil)
    case "recordHotkey":
      PluginRuntime.host("hotkeys.record", ["id": id]) { value, error in
        DispatchQueue.main.async {
          if let row = value as? [String: Any],
            let data = try? JSONSerialization.data(withJSONObject: row),
            let hotkey = try? JSONDecoder().decode(TabHotkey.self, from: data)
          {
            self.setHotkey(id, hotkey)
          }
          reply(value, error)
        }
      }
    case "clearHotkey":
      if let i = commands.firstIndex(where: { $0.id == id }) {
        commands[i].hotkey = nil
        save()
      }
      reply(payload(), nil)
    case "models": Task { reply(await AIBrain.providers(), nil) }
    case "lastRun": reply(lastRun ?? NSNull(), nil)
    default: reply(nil, "Unknown commands call: \(fn)")
    }
  }

  func payload() -> [[String: Any]] {
    commands.map {
      [
        "id": $0.id, "name": $0.name, "prompt": $0.prompt, "provider": $0.provider,
        "model": $0.model,
        "effort": $0.effort, "output": $0.output, "copyToo": $0.copyToo, "enabled": $0.enabled,
        "hotkey": $0.hotkey.map {
          ["display": $0.display, "keyCode": $0.keyCode, "modifiers": $0.modifiers] as [String: Any]
        } ?? NSNull(),
      ]
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
    guard let i = commands.firstIndex(where: { $0.id == command.id }), commands[i] != command else {
      return
    }
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

  private func save() {
    registerShortcuts()
    let snapshot = commands
    let target = fileURL
    SettingsPersistence.shared.submit(id: target.path) {
      if let data = try? JSONEncoder().encode(snapshot) {
        try? data.write(to: target, options: .atomic)
      }
    }
    PluginEvents.emit("commands", payload(), to: Self.pluginID)
  }

  func registerShortcuts() {
    PluginRuntime.host(
      "hotkeys.replace",
      [
        "items": commands.filter(\.enabled).compactMap { c -> [String: Any]? in
          guard let k = c.hotkey else { return nil }
          return [
            "id": c.id, "title": c.name, "keyCode": k.keyCode, "modifiers": k.modifiers,
            "display": k.display,
          ]
        }
      ]
    ) { _, error in if let error { PluginEvents.emit("shortcutError", error) } }
    PluginRuntime.host(
      "actions.register",
      [
        "group": "saved",
        "items": commands.filter(\.enabled).map {
          ["id": $0.id, "title": $0.name, "subtitle": "AI Command"]
        },
      ])
  }
  // MARK: Starter set (like Raycast's built-ins)

  static let defaults: [Command] = {
    func c(_ name: String, _ output: String, copyToo: Bool = false, _ prompt: String) -> Command {
      let code = ["Rewrite": 47, "Spanish translator": 44, "Explain & Translate": 41][name]
      return Command(
        id: UUID().uuidString, name: name, prompt: prompt, provider: "codex", model: "gpt-6-luna",
        effort: "none", output: output, copyToo: copyToo,
        hotkey: code.map {
          TabHotkey(
            keyCode: $0, modifiers: 1_572_864,
            display: "⌥⌘" + ([47: ".", 44: "/", 41: ";"][$0] ?? ""))
        }, enabled: true)
    }
    return [
      c(
        "Rewrite", "replace",
        """
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
      c(
        "Spanish translator", "replace", copyToo: true,
        """
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
      c(
        "Explain & Translate", "notch",
        """
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
