import AVFoundation
import AppKit
import CoreAudio

/// Permission-owning audio handles. No transcription, device preference or mixer policy lives here.
final class PluginCaptureAPI {
  static let shared = PluginCaptureAPI()
  private let queue = DispatchQueue(label: "nook.plugin.capture", qos: .userInitiated)
  private var mic: (owner: String, recorder: MicRecorder)?
  private var taps: [String: (owner: String, tap: HostAudioTap)] = [:]
  private var meterOwner: String?
  private var meter: Timer?
  func stop(_ id: String) {
    if meterOwner == id {
      meter?.invalidate()
      meter = nil
      meterOwner = nil
    }
    queue.async {
      if self.mic?.owner == id {
        _ = self.mic?.recorder.stop()
        self.mic = nil
      }
      for key in Array(self.taps.keys) where self.taps[key]?.owner == id {
        self.taps.removeValue(forKey: key)?.tap.stop()
      }
    }
  }
  func call(
    _ id: String, _ method: String, _ p: [String: Any], reply: @escaping PluginHelperProcess.Reply
  ) {
    if method == "microphone.devices" {
      queue.async {
        let rows = MicRecorder.microphones().map { ["id": $0.id, "name": $0.name] }
        DispatchQueue.main.async { reply(rows, nil) }
      }
      return
    }
    if method == "microphone.start" {
      switch AVCaptureDevice.authorizationStatus(for: .audio) {
      case .authorized: break
      case .notDetermined:
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        reply(nil, "Allow the microphone, then record again.")
        return
      default:
        reply(nil, "Allow Nook in System Settings → Privacy & Security → Microphone.")
        return
      }
    }
    queue.async {
      do {
        let value: Any
        switch method {
        case "microphone.start":
          guard self.mic == nil else {
            throw PluginEngineError("The microphone is already recording.")
          }
          let root = PluginEngine.dataDirectory(id)
          let url = try PluginFileScope.resolve(
            p["path"] as? String ?? "", dataRoot: root, scopes: [])
          guard url.pathExtension == "wav", !FileManager.default.fileExists(atPath: url.path) else {
            throw PluginEngineError("Choose a new WAV file in plugin data.")
          }
          try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
          let recorder = MicRecorder()
          try recorder.start(deviceUID: p["deviceUID"] as? String, to: url)
          try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
          self.mic = (id, recorder)
          value = NSNull()
          DispatchQueue.main.async {
            self.meterOwner = id
            self.meter?.invalidate()
            self.meter = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
              self.queue.async {
                guard let mic = self.mic, mic.owner == id else { return }
                let level = mic.recorder.meterSnapshot().level
                DispatchQueue.main.async {
                  guard Services.shared.pluginActivity?.pluginID == id else { return }
                  PluginActivities.level(id,level)
                }
              }
            }
          }
        case "microphone.stop":
          guard let mic = self.mic, mic.owner == id else {
            throw PluginEngineError("No microphone recording owned by this plugin.")
          }
          let duration = mic.recorder.stop()
          let peak = mic.recorder.meterSnapshot().peak
          self.mic = nil
          value = ["duration": duration, "peak": Int(peak)]
          DispatchQueue.main.async {
            self.meter?.invalidate()
            self.meter = nil
          }
        case "audioCapture.start":
          guard self.taps.count < 32, let processes = p["processes"] as? [UInt32],
            !processes.isEmpty, processes.count <= 128,
            let output = p["outputUID"] as? String, !output.isEmpty
          else { throw PluginEngineError("Expected process IDs and an output device UID.") }
          let tap = try HostAudioTap(processes: processes, outputUID: output, levelKey: id)
          let key = UUID().uuidString
          self.taps[key] = (id, tap)
          value = ["handle": key]
        case "audioCapture.state", "audioCapture.level", "audioCapture.update", "audioCapture.stop":
          let key = p["handle"] as? String ?? ""
          guard let entry = self.taps[key], entry.owner == id else {
            throw PluginEngineError("Unknown audio handle.")
          }
          switch method {
          case "audioCapture.state": value = ["sawSignal": entry.tap.sawSignal]
          case "audioCapture.level":
            let gain = (p["gain"] as? NSNumber)?.floatValue ?? 1
            guard gain.isFinite else { throw PluginEngineError("Gain must be finite.") }
            entry.tap.gain = max(0, min(2, gain))
            entry.tap.muted = p["muted"] as? Bool ?? false
            value = NSNull()
          case "audioCapture.update":
            guard let processes = p["processes"] as? [UInt32], !processes.isEmpty,
              processes.count <= 128
            else { throw PluginEngineError("Expected process IDs.") }
            value = entry.tap.update(processes: processes)
          default:
            self.taps.removeValue(forKey: key)?.tap.stop()
            value = NSNull()
          }
        default: throw PluginEngineError("Unknown capture method.")
        }
        DispatchQueue.main.async { reply(value, nil) }
      } catch { DispatchQueue.main.async { reply(nil, error.localizedDescription) } }
    }
  }
}
