import AudioToolbox
import CoreAudio
import Foundation

final class HostAudioTap {
  static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
      mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
  }
  private(set) var processes: [AudioObjectID]
  let outputUID: String
  let levelKey: String
  let createdAt = Date()
  private var tapUUID = UUID()
  var gain: Float = 1
  var muted = false
  private(set) var sawSignal = false

  private var tapID = AudioObjectID(kAudioObjectUnknown)
  private var aggregateID = AudioObjectID(kAudioObjectUnknown)
  private var procID: AudioDeviceIOProcID?

  struct Failure: Error { let status: OSStatus }

  init(processes: [AudioObjectID], outputUID: String, levelKey: String) throws {
    self.processes = processes
    self.outputUID = outputUID
    self.levelKey = levelKey

    let description = CATapDescription(stereoMixdownOfProcesses: processes)
    description.uuid = tapUUID
    description.muteBehavior = .mutedWhenTapped
    description.isPrivate = true
    var status = AudioHardwareCreateProcessTap(description, &tapID)
    guard status == noErr else { throw Failure(status: status) }

    let aggregate: [String: Any] = [
      kAudioAggregateDeviceNameKey: "Nook Mixer \(levelKey)",
      kAudioAggregateDeviceUIDKey: "nook.mixer.\(UUID().uuidString)",
      kAudioAggregateDeviceMainSubDeviceKey: outputUID,
      kAudioAggregateDeviceIsPrivateKey: true,
      kAudioAggregateDeviceIsStackedKey: false,
      kAudioAggregateDeviceTapAutoStartKey: true,
      kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
      kAudioAggregateDeviceTapListKey: [
        [kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]
      ],
    ]
    status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
    guard status == noErr else {
      stop()
      throw Failure(status: status)
    }

    status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) {
      [weak self] _, input, _, output, _ in
      self?.render(input, output)
    }
    guard status == noErr else {
      stop()
      throw Failure(status: status)
    }
    status = AudioDeviceStart(aggregateID, procID)
    guard status == noErr else {
      stop()
      throw Failure(status: status)
    }
  }

  /// Copy tapped audio to the output with gain. Above 100% a soft clip keeps boosts from crackling.
  private func render(
    _ input: UnsafePointer<AudioBufferList>, _ output: UnsafeMutablePointer<AudioBufferList>
  ) {
    let gain = muted ? 0 : gain
    let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
    let outputs = UnsafeMutableAudioBufferListPointer(output)
    for (index, out) in outputs.enumerated() {
      guard let outData = out.mData?.assumingMemoryBound(to: Float32.self) else { continue }
      let outChannels = max(1, Int(out.mNumberChannels))
      let outFrames = Int(out.mDataByteSize) / MemoryLayout<Float32>.size / outChannels
      guard !inputs.isEmpty,
        let inData = inputs[index % inputs.count].mData?.assumingMemoryBound(to: Float32.self)
      else {
        memset(out.mData, 0, Int(out.mDataByteSize))
        continue
      }
      let inBuffer = inputs[index % inputs.count]
      let inChannels = max(1, Int(inBuffer.mNumberChannels))
      let inFrames = Int(inBuffer.mDataByteSize) / MemoryLayout<Float32>.size / inChannels
      let frames = min(outFrames, inFrames)
      var peak: Float32 = 0
      for frame in 0..<frames {
        for channel in 0..<outChannels {
          // One interleaved input (the tap's stereo mix) feeding separate per-channel output buffers: keep L/R apart.
          let source =
            inputs.count == 1 ? (index * outChannels + channel) % inChannels : channel % inChannels
          let sample = inData[frame * inChannels + source]
          peak = max(peak, abs(sample))
          var v = sample * gain
          if gain > 1 { v = tanhf(v) }  // soft clip only when boosting
          outData[frame * outChannels + channel] = v
        }
      }
      if frames < outFrames {
        memset(
          outData + frames * outChannels, 0,
          (outFrames - frames) * outChannels * MemoryLayout<Float32>.size)
      }
      if peak > 0.0001 { sawSignal = true }
    }
  }

  /// Point the live tap at a new set of processes without touching the aggregate device.
  func update(processes new: [AudioObjectID]) -> Bool {
    guard tapID != kAudioObjectUnknown else { return false }
    let description = CATapDescription(stereoMixdownOfProcesses: new)
    description.uuid = tapUUID
    description.muteBehavior = .mutedWhenTapped
    description.isPrivate = true
    var address = HostAudioTap.address(kAudioTapPropertyDescription)
    var object: CATapDescription = description
    let status = withUnsafeMutablePointer(to: &object) {
      AudioObjectSetPropertyData(
        tapID, &address, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), $0)
    }
    if status == noErr { processes = new }
    return status == noErr
  }

  func stop() {
    if let procID, aggregateID != kAudioObjectUnknown {
      AudioDeviceStop(aggregateID, procID)
      AudioDeviceDestroyIOProcID(aggregateID, procID)
    }
    procID = nil
    if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
    aggregateID = AudioObjectID(kAudioObjectUnknown)
    if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
    tapID = AudioObjectID(kAudioObjectUnknown)
  }

  deinit { stop() }
}
