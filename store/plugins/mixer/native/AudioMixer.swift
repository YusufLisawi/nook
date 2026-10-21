import AppKit
import AudioToolbox
import CoreAudio

/// Volume mixer engine: output/input devices (default, volume, mute, "keep as default") and per-app volume 0–200%.
///
/// Per-app volume uses Core Audio process taps (macOS 14.2+): the app's audio is tapped with `mutedWhenTapped`,
/// so the original goes silent, and we play the tapped audio to the output device with our gain. Taps only exist
/// while an app is not at 100% (or is muted) — at 100% the app plays untouched.
final class AudioMixer {
  struct Device {
    let id: AudioObjectID
    let uid: String
    let name: String
  }

  enum Kind: String { case output, input }

  private let queue = DispatchQueue(label: "nook.audio")
  private var taps: [String: AppTap] = [:]  // app key → live tap
  private var levels: [String: AppLevel]  // app key → saved gain/mute (keyed by bundle id or app path)
  private var iconCache: [String: String] = [:]
  private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
  private var listening = false
  private var refreshWork: DispatchWorkItem?
  /// Set when a tap delivered only silence while the app was playing: audio capture permission is missing.
  private(set) var needsPermission = false

  private struct AppLevel: Codable {
    var gain: Float
    var muted: Bool
  }

  private enum Keys {
    static let levels = "audioAppLevels"
    static let preferredInput = "audioPreferredInputUID"
    static let preferredOutput = "audioPreferredOutputUID"
  }

  init() {
    let data = PluginDefaults.standard.data(forKey: Keys.levels)
    levels = data.flatMap { try? JSONDecoder().decode([String: AppLevel].self, from: $0) } ?? [:]
  }

  // MARK: Lifecycle

  func start() {
    queue.async {
      self.listen()
      self.enforcePreferredDevices()
      self.syncTaps()
    }
  }

  func shutdown() {
    queue.sync {
      listening = false
      refreshWork?.cancel()
      refreshWork = nil
      pollTimer?.cancel()
      pollTimer = nil
      let system = AudioObjectID(kAudioObjectSystemObject)
      for (var address, block) in listeners {
        AudioObjectRemovePropertyListenerBlock(system, &address, queue, block)
      }
      listeners = []
      iconCache = [:]
      taps.values.forEach { $0.stop() }
      taps.removeAll()
    }
  }

  // MARK: Bridge

  func handle(_ fn: String, args: [Any], reply: @escaping (Any?, String?) -> Void) {
    let str = { (i: Int) in i < args.count ? args[i] as? String ?? "" : "" }
    let num = { (i: Int) in i < args.count ? (args[i] as? NSNumber)?.floatValue ?? 0 : 0 }
    let bool = { (i: Int) in i < args.count ? (args[i] as? Bool) ?? false : false }
    queue.async {
      switch fn {
      case "state": break
      case "setDefault": self.setDefault(Kind(rawValue: str(0)) ?? .output, uid: str(1))
      case "setDeviceVolume":
        self.setDeviceVolume(Kind(rawValue: str(0)) ?? .output, uid: str(1), volume: num(2))
      case "setDeviceMute":
        self.setDeviceMute(Kind(rawValue: str(0)) ?? .output, uid: str(1), muted: bool(2))
      case "setPreferred":
        let key = str(0) == "input" ? Keys.preferredInput : Keys.preferredOutput
        let uid = str(1)
        PluginDefaults.standard.set(uid.isEmpty ? nil : uid, forKey: key)
        self.enforcePreferredDevices()
      case "setAppVolume": self.setApp(str(0)) { $0.gain = max(0, min(2, num(1))) }
      case "setAppMute": self.setApp(str(0)) { $0.muted = bool(1) }
      case "resetApp": self.setApp(str(0)) { $0 = AppLevel(gain: 1, muted: false) }
      case "openPrivacy":
        DispatchQueue.main.async {
          NSWorkspace.shared.open(
            URL(
              string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture"
            )!)
        }
      default:
        return reply(nil, "Unknown audio call: \(fn)")
      }
      let state = self.state()
      reply(state, nil)
    }
  }

  // MARK: State

  private func state() -> [String: Any] {
    let outDefault = Self.defaultDevice(.output)
    let inDefault = Self.defaultDevice(.input)
    let deviceInfo = { (kind: Kind, d: Device, def: AudioObjectID) -> [String: Any] in
      [
        "uid": d.uid, "name": d.name, "isDefault": d.id == def,
        "volume": Self.volume(d.id, kind) ?? NSNull(), "muted": Self.isMuted(d.id, kind),
      ]
    }
    return [
      "output": [
        "devices": Self.devices(.output).map { deviceInfo(.output, $0, outDefault) },
        "preferredUID": PluginDefaults.standard.string(forKey: Keys.preferredOutput).map {
          $0 as Any
        } ?? NSNull(),
      ],
      "input": [
        "devices": Self.devices(.input).map { deviceInfo(.input, $0, inDefault) },
        "preferredUID": PluginDefaults.standard.string(forKey: Keys.preferredInput).map {
          $0 as Any
        } ?? NSNull(),
        "level": Self.inputLevelHint(inDefault),
      ],
      "apps": appGroups().filter { $0.playing || taps[$0.key] != nil }.map { g -> [String: Any] in
        let level = levels[g.levelKey] ?? AppLevel(gain: 1, muted: false)
        return [
          "id": g.levelKey, "name": g.name, "bundleId": g.bundleID.map { $0 as Any } ?? NSNull(),
          "icon": icon(for: g.path),
          "volume": level.gain, "muted": level.muted, "playing": g.playing,
          "boosted": taps[g.key] != nil,
        ]
      },
      "needsPermission": needsPermission,
    ]
  }

  private func setApp(_ levelKey: String, _ change: (inout AppLevel) -> Void) {
    guard !levelKey.isEmpty else { return }
    var level = levels[levelKey] ?? AppLevel(gain: 1, muted: false)
    change(&level)
    if level.gain == 1, !level.muted {
      levels.removeValue(forKey: levelKey)
    } else {
      levels[levelKey] = level
    }
    PluginDefaults.standard.set(try? JSONEncoder().encode(levels), forKey: Keys.levels)
    if let tap = taps.values.first(where: { $0.levelKey == levelKey }) {
      tap.gain = level.gain
      tap.muted = level.muted
    }
    needsPermission = false
    syncTaps()
  }

  // MARK: Apps & taps

  private struct AppGroup {
    let key: String  // app bundle path (or bundle id / pid)
    let levelKey: String  // what we save volumes under: bundle id when known
    let name: String
    let bundleID: String?
    let path: String?
    var processes: [AudioObjectID]
    var playing: Bool
    var outputProcesses: [AudioObjectID] = []  // only these get tapped
    var recording = false  // app is using a microphone right now
  }

  /// Audio processes grouped by the app responsible for them (helpers, GPU/renderer processes → their app).
  private func appGroups() -> [AppGroup] {
    let myPID = pid_t(
      ProcessInfo.processInfo.environment["NOOK_HOST_PID"].flatMap(Int32.init)
        ?? ProcessInfo.processInfo.processIdentifier)
    var groups: [String: AppGroup] = [:]
    for object in Self.readIDs(
      AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
    {
      let pid: pid_t = Self.read(object, kAudioProcessPropertyPID, default: 0)
      guard pid > 0 else { continue }
      let owner = Self.responsiblePID(pid)
      guard owner != myPID, pid != myPID else { continue }
      let running: UInt32 = Self.read(object, kAudioProcessPropertyIsRunningOutput, default: 0)
      let app =
        NSRunningApplication(processIdentifier: owner)
        ?? NSRunningApplication(processIdentifier: pid)
      let path = app?.bundleURL.map { Self.outermostApp($0.path) }
      guard let path, path.hasSuffix(".app") else { continue }  // daemons (coreaudiod, etc.)
      let bundleID = Bundle(path: path)?.bundleIdentifier ?? app?.bundleIdentifier
      let name =
        app?.localizedName
        ?? FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")
      var group =
        groups[path]
        ?? AppGroup(
          key: path, levelKey: bundleID ?? path, name: name, bundleID: bundleID, path: path,
          processes: [], playing: false)
      group.processes.append(object)
      group.playing = group.playing || running != 0
      if running != 0 { group.outputProcesses.append(object) }
      let input: UInt32 = Self.read(object, kAudioProcessPropertyIsRunningInput, default: 0)
      group.recording = group.recording || input != 0
      groups[path] = group
    }
    return groups.values.sorted {
      $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
  }

  /// Create/update/remove taps so they match the saved levels for running apps.
  private func syncTaps() {
    updatePolling()
    guard !taps.isEmpty || levels.values.contains(where: { $0.gain != 1 || $0.muted }) else {
      return
    }
    let output = Self.defaultDevice(.output)
    guard output != kAudioObjectUnknown, let outputUID = Self.uid(output) else { return }
    let groups = appGroups()
    var wanted: Set<String> = []
    for group in groups {
      guard let level = levels[group.levelKey], level.gain != 1 || level.muted else { continue }
      wanted.insert(group.key)
      if let tap = taps[group.key], tap.outputUID == outputUID {
        // Re-tap only when the set of processes actually playing sound changes — and never while the app is
        // recording: rebuilding swaps an aggregate device, which browser recorders see as "mic disconnected".
        let playing = Set(group.outputProcesses)
        if !playing.isEmpty, playing != Set(tap.processes), !group.recording,
          !tap.update(processes: group.outputProcesses),
          Date().timeIntervalSince(tap.createdAt) > 30
        {
          rebuild(group: group, level: level, outputUID: outputUID)
        }
        continue
      }
      guard !group.outputProcesses.isEmpty, !group.recording else { continue }  // nothing to tap yet / don't disturb a recording
      // Missing audio-capture permission: don't retry every 2 s; wait until the user changes a level again.
      guard !needsPermission else { continue }
      rebuild(group: group, level: level, outputUID: outputUID)
    }
    for key in taps.keys where !wanted.contains(key) {
      taps.removeValue(forKey: key)?.stop()
    }
  }

  private func rebuild(group: AppGroup, level: AppLevel, outputUID: String) {
    taps[group.key]?.stop()
    do {
      let tap = try AppTap(
        processes: group.outputProcesses, outputUID: outputUID, levelKey: group.levelKey)
      tap.gain = level.gain
      tap.muted = level.muted
      taps[group.key] = tap
      watchForSilence(tap, key: group.key)
    } catch {
      taps.removeValue(forKey: group.key)
    }
  }

  /// No permission → the tap gives silence while the app's original is muted. Detect it and back off.
  private func watchForSilence(_ tap: AppTap, key: String) {
    queue.asyncAfter(deadline: .now() + 2) { [weak self, weak tap] in
      guard let self, let tap, self.taps[key] === tap, !tap.sawSignal else { return }
      let stillPlaying = tap.processes.contains {
        (Self.read($0, kAudioProcessPropertyIsRunningOutput, default: UInt32(0))) != 0
      }
      guard stillPlaying, !tap.muted, tap.gain > 0 else { return }
      tap.stop()
      self.taps.removeValue(forKey: key)
      self.needsPermission = true
      if FeatureVisibility.isVisible("mixer") { PluginEvents.emit("audio", self.state()) }
    }
  }

  // MARK: Devices

  private func setDefault(_ kind: Kind, uid: String) {
    guard let device = Self.devices(kind).first(where: { $0.uid == uid }) else { return }
    var id = device.id
    var address = Self.address(
      kind == .output
        ? kAudioHardwarePropertyDefaultOutputDevice : kAudioHardwarePropertyDefaultInputDevice)
    AudioObjectSetPropertyData(
      AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
      UInt32(MemoryLayout<AudioObjectID>.size), &id)
    if kind == .output {
      // System sounds follow the main output too.
      var sys = Self.address(kAudioHardwarePropertyDefaultSystemOutputDevice)
      AudioObjectSetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &sys, 0, nil,
        UInt32(MemoryLayout<AudioObjectID>.size), &id)
    }
  }

  private func setDeviceVolume(_ kind: Kind, uid: String, volume: Float) {
    guard let device = Self.devices(kind).first(where: { $0.uid == uid }) else { return }
    var value = max(0, min(1, volume))
    var address = Self.address(
      kAudioHardwareServiceDeviceProperty_VirtualMainVolume, Self.scope(kind))
    if AudioObjectHasProperty(device.id, &address) {
      AudioObjectSetPropertyData(
        device.id, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
    } else {
      for channel: UInt32 in [0, 1, 2] {  // devices without a main control: set each channel
        var a = Self.address(kAudioDevicePropertyVolumeScalar, Self.scope(kind), channel)
        if AudioObjectHasProperty(device.id, &a) {
          AudioObjectSetPropertyData(
            device.id, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
        }
      }
    }
    if value > 0, Self.isMuted(device.id, kind) { setDeviceMute(kind, uid: uid, muted: false) }
  }

  private func setDeviceMute(_ kind: Kind, uid: String, muted: Bool) {
    guard let device = Self.devices(kind).first(where: { $0.uid == uid }) else { return }
    var value: UInt32 = muted ? 1 : 0
    var address = Self.address(kAudioDevicePropertyMute, Self.scope(kind))
    AudioObjectSetPropertyData(
      device.id, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
  }

  /// "Keep as default": if macOS switches devices (AirPods connect, etc.), switch back to the pinned one.
  private func enforcePreferredDevices() {
    for (kind, key) in [(Kind.input, Keys.preferredInput), (Kind.output, Keys.preferredOutput)] {
      guard let uid = PluginDefaults.standard.string(forKey: key),
        let device = Self.devices(kind).first(where: { $0.uid == uid }),
        Self.defaultDevice(kind) != device.id
      else { continue }
      setDefault(kind, uid: uid)
    }
  }

  private func listen() {
    guard !listening else { return }
    listening = true
    let system = AudioObjectID(kAudioObjectSystemObject)
    for selector in [
      kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultInputDevice,
      kAudioHardwarePropertyDevices, kAudioHardwarePropertyProcessObjectList,
    ] {
      var address = Self.address(selector)
      let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.scheduleRefresh() }
      AudioObjectAddPropertyListenerBlock(system, &address, queue, block)
      listeners.append((address, block))
    }
    updatePolling()
  }

  private func updatePolling() {
    let needed = levels.values.contains { $0.gain != 1 || $0.muted }
    PluginRuntime.host(
      "runtime.keepAlive",
      [
        "enabled": needed
          || !(PluginDefaults.standard.string(forKey: Keys.preferredInput) ?? "").isEmpty
          || !(PluginDefaults.standard.string(forKey: Keys.preferredOutput) ?? "").isEmpty
      ])
    if !needed {
      pollTimer?.cancel()
      pollTimer = nil
      return
    }
    guard listening, pollTimer == nil else { return }
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + 5, repeating: 5, leeway: .seconds(1))
    timer.setEventHandler { [weak self] in self?.syncTaps() }
    timer.resume()
    pollTimer = timer
  }

  private var pollTimer: DispatchSourceTimer?

  private func scheduleRefresh() {
    guard listening else { return }
    refreshWork?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self, self.listening else { return }
      self.enforcePreferredDevices()
      self.syncTaps()
      if FeatureVisibility.isVisible("mixer") { PluginEvents.emit("audio", self.state()) }
    }
    refreshWork = work
    queue.asyncAfter(deadline: .now() + 0.25, execute: work)
  }

  // MARK: Icons

  private func icon(for path: String?) -> String {
    guard let path else { return "" }
    if let cached = iconCache[path] { return cached }
    let image = NSWorkspace.shared.icon(forFile: path)
    let size = NSSize(width: 64, height: 64)
    let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 4,
      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    var url = ""
    if let rep {
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
      image.draw(in: NSRect(origin: .zero, size: size))
      NSGraphicsContext.restoreGraphicsState()
      if let png = rep.representation(using: .png, properties: [:]) {
        url = "data:image/png;base64," + png.base64EncodedString()
      }
    }
    iconCache[path] = url
    return url
  }

  // MARK: Core Audio helpers

  static func address(
    _ selector: AudioObjectPropertySelector,
    _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
  ) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
  }

  static func scope(_ kind: Kind) -> AudioObjectPropertyScope {
    kind == .output ? kAudioObjectPropertyScopeOutput : kAudioObjectPropertyScopeInput
  }

  static func read<T>(
    _ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
    _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, default value: T
  ) -> T {
    var address = address(selector, scope)
    var result = value
    var size = UInt32(MemoryLayout<T>.size)
    let status = withUnsafeMutablePointer(to: &result) {
      AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
    }
    return status == noErr ? result : value
  }

  static func readIDs(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector)
    -> [AudioObjectID]
  {
    var address = address(selector)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else {
      return []
    }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids) == noErr else {
      return []
    }
    return ids
  }

  static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var address = address(selector)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else {
      return nil
    }
    return value?.takeRetainedValue() as String?
  }

  static func uid(_ device: AudioObjectID) -> String? {
    string(device, kAudioDevicePropertyDeviceUID)
  }

  static func devices(_ kind: Kind) -> [Device] {
    readIDs(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices).compactMap {
      id in
      var address = address(kAudioDevicePropertyStreams, scope(kind))
      var size: UInt32 = 0
      guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0,
        let uid = uid(id), let name = string(id, kAudioObjectPropertyName)
      else { return nil }
      // Hide virtual plumbing (aggregates other apps made, zoom/teams drivers stay visible).
      if uid.hasPrefix("CADefaultDeviceAggregate") || name.hasPrefix("Nook ") { return nil }
      return Device(id: id, uid: uid, name: name)
    }
  }

  static func defaultDevice(_ kind: Kind) -> AudioObjectID {
    read(
      AudioObjectID(kAudioObjectSystemObject),
      kind == .output
        ? kAudioHardwarePropertyDefaultOutputDevice : kAudioHardwarePropertyDefaultInputDevice,
      default: AudioObjectID(kAudioObjectUnknown))
  }

  static func volume(_ device: AudioObjectID, _ kind: Kind) -> Float? {
    var address = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope(kind))
    if AudioObjectHasProperty(device, &address) {
      return read(
        device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope(kind),
        default: Float32(0))
    }
    for channel: UInt32 in [0, 1] {
      var a = Self.address(kAudioDevicePropertyVolumeScalar, scope(kind), channel)
      var value: Float32 = 0
      var size = UInt32(MemoryLayout<Float32>.size)
      if AudioObjectHasProperty(device, &a),
        AudioObjectGetPropertyData(device, &a, 0, nil, &size, &value) == noErr
      {
        return value
      }
    }
    return nil  // fixed-volume device
  }

  static func isMuted(_ device: AudioObjectID, _ kind: Kind) -> Bool {
    read(device, kAudioDevicePropertyMute, scope(kind), default: UInt32(0)) != 0
  }

  private static func inputLevelHint(_ device: AudioObjectID) -> Any {
    volume(device, .input) ?? NSNull()
  }

  /// "/Applications/Arc.app/Contents/Frameworks/…/Helper.app" → "/Applications/Arc.app"
  static func outermostApp(_ path: String) -> String {
    guard let range = path.range(of: ".app/") else { return path }
    return String(path[..<range.lowerBound]) + ".app"
  }

  /// The app that "owns" a helper process (e.g. WebKit GPU process → Safari). Private but stable libSystem call.
  private static let responsibility: (@convention(c) (pid_t) -> pid_t)? = {
    guard
      let symbol = dlsym(
        UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
    else { return nil }
    return unsafeBitCast(symbol, to: (@convention(c) (pid_t) -> pid_t).self)
  }()

  static func responsiblePID(_ pid: pid_t) -> pid_t {
    let owner = responsibility?(pid) ?? pid
    return owner > 0 ? owner : pid
  }
}

/// Opaque host-owned tap. Core Audio capture always runs in the signed Nook process.
private final class AppTap {
  let handle: String
  private(set) var processes: [AudioObjectID]
  let outputUID: String
  let levelKey: String
  let createdAt = Date()
  var gain: Float = 1 { didSet { updateLevel() } }
  var muted = false { didSet { updateLevel() } }
  var sawSignal: Bool {
    ((try? PluginRuntime.sync("audioCapture.state", ["handle": handle])) as? [String: Any])?[
      "sawSignal"] as? Bool ?? false
  }
  init(processes: [AudioObjectID], outputUID: String, levelKey: String) throws {
    self.processes = processes
    self.outputUID = outputUID
    self.levelKey = levelKey
    let row =
      try PluginRuntime.sync(
        "audioCapture.start", ["processes": processes, "outputUID": outputUID]) as? [String: Any]
    guard let handle = row?["handle"] as? String else {
      throw HelperFailure(message: "No audio tap handle.")
    }
    self.handle = handle
  }
  private func updateLevel() {
    PluginRuntime.host("audioCapture.level", ["handle": handle, "gain": gain, "muted": muted])
  }
  func update(processes: [AudioObjectID]) -> Bool {
    let ok =
      (try? PluginRuntime.sync("audioCapture.update", ["handle": handle, "processes": processes]))
      as? Bool ?? false
    if ok { self.processes = processes }
    return ok
  }
  func stop() { PluginRuntime.host("audioCapture.stop", ["handle": handle]) }
  deinit { stop() }
}
