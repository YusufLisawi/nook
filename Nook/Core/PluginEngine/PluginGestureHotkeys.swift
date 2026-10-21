import AppKit

/// Modifier gestures share Nook's existing event tap. Helpers do not install taps or listen while idle.
final class PluginGestureHotkeys {
  static let shared = PluginGestureHotkeys()
  private var owners: [String: (String, String, DictationShortcut)] = [:]
  var needed: Bool { !owners.isEmpty }
  var items: [SettingsShortcutItem] {
    owners.map { mode, value in
      SettingsShortcutItem(
        id: "gesture:" + value.0 + "/" + value.1, title: value.2.display + " · " + value.1,
        group: "Plugin gestures", allowsModifierOnly: true, editable: false, get: { value.2 },
        set: { _ in })
    }
  }
  func register(_ id: String, _ p: [String: Any]) throws {
    guard let mode = p["mode"] as? String, ["hold", "toggle"].contains(mode),
      let action = p["id"] as? String, !action.isEmpty,
      let modifiers = p["modifiers"] as? UInt64, modifiers != 0,
      owners[mode] == nil || owners[mode]?.0 == id
    else { throw PluginEngineError("This hold/toggle gesture is already owned, or invalid.") }
    let key = DictationShortcut(
      keyCode: p["keyCode"] as? Int, modifiers: modifiers, display: p["display"] as? String ?? mode)
    if let code = key.keyCode, !(0...127).contains(code) {
      throw PluginEngineError("Invalid gesture key code.")
    }
    if let conflict = SettingsShortcutItem.all.first(where: {
      $0.id != "gesture:" + id + "/" + action
        && $0.get().map { ShortcutIdentity($0) == ShortcutIdentity(key) } == true
    }) {
      throw PluginEngineError("Shortcut conflicts with \(conflict.title).")
    }
    owners[mode] = (id, action, key)
    configure()
  }
  func unregister(_ id: String, action: String) {
    owners = owners.filter { $0.value.0 != id || $0.value.1 != action }
    configure()
  }
  func remove(_ id: String) {
    owners = owners.filter { $0.value.0 != id }
    configure()
  }
  private func configure() {
    let monitor = Services.shared.hotkeys
    monitor.hold = owners["hold"]?.2
    monitor.toggle = owners["toggle"]?.2
    monitor.onHoldStart = { self.emit("hold", "pressed") }
    monitor.onHoldEnd = { self.emit("hold", "released") }
    monitor.onHoldCancel = { self.emit("hold", "cancelled") }
    monitor.onToggle = { self.emit("toggle", "pressed") }
    Features.shared.refreshHotkeys()
    NotificationCenter.default.post(name: .nookShortcutsChanged, object: nil)
  }
  private func emit(_ mode: String, _ phase: String) {
    guard let (id, action, _) = owners[mode] else { return }
    PluginEvents.emit(
      "hotkey",
      [
        "id": action, "phase": phase,
        "context": PluginHostAPI.shared.shortcutContext as Any? ?? NSNull(),
      ], to: id)
  }
}

/// Explicit editor action only; ordinary shortcuts are suspended until capture completes or times out.
final class PluginHotkeyRecorder {
  static let shared = PluginHotkeyRecorder()
  private var owner: String?
  private var generation = UUID()
  private var monitor: Any?
  private var finish: PluginHelperProcess.Reply?
  private var peak: CGEventFlags = []
  func record(
    owner: String, action: String, modifierOnly: Bool, reply: @escaping PluginHelperProcess.Reply
  ) {
    complete(nil, "Shortcut recording was replaced.")
    self.owner = owner
    generation = UUID()
    let token = generation
    finish = { value, error in
      if let row = value as? [String: Any], let flags = row["modifiers"] as? UInt64 {
        let shortcut = DictationShortcut(
          keyCode: row["keyCode"] as? Int, modifiers: flags,
          display: row["display"] as? String ?? "")
        let except = [
          "extension:plugin." + owner + "/" + action, "gesture:" + owner + "/" + action,
        ]
        if let other = SettingsShortcutItem.all.first(where: {
          !except.contains($0.id)
            && $0.get().map { ShortcutIdentity($0) == ShortcutIdentity(shortcut) } == true
        }) {
          reply(nil, "Shortcut conflicts with \(other.title).")
          return
        }
        if let code = shortcut.keyCode,
          let other = ShortcutRegistry.externalConflicts(
            TabHotkey(keyCode: code, modifiers: flags, display: shortcut.display)
          ).first
        {
          reply(nil, "Shortcut conflicts with \(other).")
          return
        }
      }
      reply(value, error)
    }
    peak = []
    Services.shared.hotkeys.paused = true
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
      if event.type == .flagsChanged {
        let flags = Modifiers.from(event.modifierFlags)
        if !flags.isEmpty {
          self.peak.formUnion(flags)
        } else if modifierOnly, !self.peak.isEmpty {
          self.complete(
            ["modifiers": self.peak.rawValue, "display": Modifiers.symbols(self.peak)], nil)
        }
        return event
      }
      if event.keyCode == 53 {
        self.complete(nil, "Shortcut recording cancelled.")
        return nil
      }
      if event.keyCode == 51 {
        self.complete(NSNull(), nil)
        return nil
      }
      guard let key = TabHotkeys.make(from: event) else { return nil }
      self.complete(
        ["keyCode": key.keyCode, "modifiers": key.modifiers, "display": key.display], nil)
      return nil
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
      if self.generation == token { self.complete(nil, "Shortcut recording timed out.") }
    }
  }
  func stop(_ id: String) { if owner == id { complete(nil, "Plugin stopped.") } }
  func complete(_ value: Any?, _ error: String?) {
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
    let reply = finish
    finish = nil
    owner = nil
    if reply != nil {
      Services.shared.hotkeys.paused = false
      reply?(value, error)
    }
  }
}
