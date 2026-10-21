import AVFoundation

/// Records a chosen microphone to a lossless 16 kHz mono PCM16 WAV — the same shape FreeFlow uploads.
/// (AVAudioRecorder could only use the system default mic and we were writing lossy AAC.)
final class MicRecorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    struct Mic: Identifiable, Hashable {
        let id: String // AVCaptureDevice.uniqueID
        let name: String
    }

    static let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!

    /// A fresh session per recording: one kept across sleep/wake or device changes can keep "running" while delivering
    /// only silence (all-zero buffers), which came back as empty transcriptions.
    private var session = AVCaptureSession()
    private let queue = DispatchQueue(label: "nook.mic")
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private(set) var level: Float = 0
    private(set) var framesWritten: AVAudioFramePosition = 0
    /// Loudest sample of the current/last recording (0 = the mic delivered pure silence).
    private(set) var peak: Int16 = 0

    func meterSnapshot() -> (level: Float, peak: Int16) { queue.sync { (level, peak) } }

    static func microphones() -> [Mic] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
            .devices.map { Mic(id: $0.uniqueID, name: $0.localizedName) }
    }

    /// The chosen mic if it's connected, otherwise the system default.
    static func device(for uid: String?) -> AVCaptureDevice? {
        if let uid, !uid.isEmpty, let device = AVCaptureDevice(uniqueID: uid) { return device }
        return AVCaptureDevice.default(for: .audio)
    }

    func start(deviceUID: String?, to url: URL) throws {
        guard let device = Self.device(for: deviceUID) else { throw NSError(domain: "Nook", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone found"]) }
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()
        // Ask Core Audio for our exact format so it resamples with its high-quality converter.
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ]
        output.setSampleBufferDelegate(self, queue: queue)

        if session.isRunning { session.stopRunning() }
        session = AVCaptureSession()
        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            throw NSError(domain: "Nook", code: 2, userInfo: [NSLocalizedDescriptionKey: "Couldn't use \(device.localizedName)"])
        }
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()

        try queue.sync {
            file = try AVAudioFile(forWriting: url, settings: Self.target.settings, commonFormat: .pcmFormatInt16, interleaved: true)
            converter = nil
            framesWritten = 0
            peak = 0
            level = 0
        }
        session.startRunning()
    }

    /// Stops and closes the file; returns the recorded duration in seconds.
    func stop() -> Double {
        session.stopRunning()
        return queue.sync {
            let seconds = Double(framesWritten) / Self.target.sampleRate
            file = nil // closes the WAV
            level = 0
            return seconds
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let file, let description = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let source = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList) == noErr else { return }

        var out = buffer
        if source != Self.target { // settings weren't honoured exactly → convert ourselves
            if converter == nil { converter = AVAudioConverter(from: source, to: Self.target) }
            let capacity = AVAudioFrameCount(Double(frames) * Self.target.sampleRate / source.sampleRate) + 32
            guard let converter, let converted = AVAudioPCMBuffer(pcmFormat: Self.target, frameCapacity: capacity) else { return }
            var fed = false
            converter.convert(to: converted, error: nil) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            out = converted
        }
        try? file.write(from: out)
        framesWritten += AVAudioFramePosition(out.frameLength)

        if let samples = out.int16ChannelData?[0] {
            var sum: Float = 0
            let n = Int(out.frameLength)
            for i in 0..<n {
                let v = Float(samples[i]) / 32768; sum += v * v
                peak = max(peak, samples[i] == .min ? .max : abs(samples[i]))
            }
            let rms = n > 0 ? sqrt(sum / Float(n)) : 0
            level = min(1, rms * 6) // speech sits low; scale up for the meter
        }
    }
}
