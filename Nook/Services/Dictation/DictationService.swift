import AppKit
import AVFoundation

final class DictationService: ObservableObject {
    enum Phase: Equatable { case idle, recording, transcribing, done, failed }

    struct Entry: Codable, Identifiable {
        var id: String
        var date: Date
        var audio: String
        var raw: String?
        var text: String?
        var status: String // done | failed | transcribing
        var error: String?
        var duration: Double
    }

    enum Keys {
        static let prompt = "dictationPrompt"
        static let vocabulary = "dictationVocabulary"
        static let cleanup = "dictationCleanup"
        static let sounds = "dictationSounds"
        static let groqSecret = "groq_api_key"
        static let holdShortcut = "dictationHoldShortcut"
        static let toggleShortcut = "dictationToggleShortcut"
    }

    static let defaultPrompt = "You are a literal dictation cleanup layer. Fix punctuation, capitalisation and obvious transcription mistakes. Remove filler words. Keep the speaker's wording and language. Return only the cleaned text."

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var level: Float = 0
    @Published private(set) var history: [Entry] = []

    let hotkeys = HotkeyMonitor()
    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private var current: (id: String, url: URL, started: Date)?
    private var idleWork: DispatchWorkItem?

    private static var dir: URL {
        let dir = Services.supportDir.appendingPathComponent("Dictation/audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private static var historyURL: URL { Services.supportDir.appendingPathComponent("Dictation/history.json") }

    var apiKey: String? { Secrets.get(Keys.groqSecret) }

    func start() {
        UserDefaults.standard.register(defaults: [Keys.cleanup: true, Keys.sounds: true, Keys.prompt: Self.defaultPrompt, Keys.vocabulary: ""])
        importFromFreeFlow()
        loadHistory()
        // Anything still "transcribing" was interrupted by a quit.
        for i in history.indices where history[i].status == "transcribing" {
            history[i].status = "failed"
            history[i].error = "Interrupted"
        }
        hotkeys.onHoldStart = { [weak self] in self?.begin() }
        hotkeys.onHoldEnd = { [weak self] in self?.finish() }
        hotkeys.onHoldCancel = { [weak self] in self?.finish(cancel: true) }
        hotkeys.onToggle = { [weak self] in self?.toggle() }
        reloadShortcuts()
        hotkeys.start()
    }

    /// One-time import of the user's FreeFlow key, prompt and vocabulary.
    func importFromFreeFlow() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "dictationImportedFreeFlow") else { return }
        defaults.set(true, forKey: "dictationImportedFreeFlow")
        let settings = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("FreeFlow/.settings")
        if apiKey == nil, let data = try? Data(contentsOf: settings),
           let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: String], let key = dict["groq_api_key"], !key.isEmpty {
            Secrets.set(Keys.groqSecret, key)
        }
        if let ff = UserDefaults(suiteName: "com.zachlatta.freeflow") {
            if let prompt = ff.string(forKey: "custom_system_prompt"), !prompt.isEmpty {
                defaults.set(prompt.replacingOccurrences(of: "\\n", with: "\n"), forKey: Keys.prompt)
            }
            if let vocab = ff.string(forKey: "custom_vocabulary"), !vocab.isEmpty {
                defaults.set(vocab.replacingOccurrences(of: "\\n", with: "\n"), forKey: Keys.vocabulary)
            }
        }
    }

    func reloadShortcuts() {
        hotkeys.hold = DictationShortcut.load(Keys.holdShortcut, fallback: .defaultHold)
        hotkeys.toggle = DictationShortcut.load(Keys.toggleShortcut, fallback: .defaultToggle)
        PluginEvents.emit("dictation", historyPayload())
    }

    // MARK: Recording

    func toggle() { phase == .recording ? finish() : begin() }

    func begin() {
        guard phase != .recording else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            return
        default:
            flash(.failed)
            Notifier.post(title: "Nook can't hear you", body: "Allow the microphone in System Settings → Privacy → Microphone.")
            return
        }
        let id = UUID().uuidString
        let url = Self.dir.appendingPathComponent("\(id).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        guard let recorder = try? AVAudioRecorder(url: url, settings: settings) else { return flash(.failed) }
        recorder.isMeteringEnabled = true
        recorder.record()
        self.recorder = recorder
        current = (id, url, Date())
        idleWork?.cancel()
        phase = .recording
        sound("Tink")
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            guard let recorder = self?.recorder else { return }
            recorder.updateMeters()
            self?.level = max(0, min(1, (recorder.averagePower(forChannel: 0) + 50) / 50))
        }
    }

    func finish(cancel: Bool = false) {
        guard phase == .recording, let recorder, let current else { return }
        recorder.stop()
        meterTimer?.invalidate()
        self.recorder = nil
        self.current = nil
        level = 0
        let duration = Date().timeIntervalSince(current.started)
        if cancel || duration < 0.4 { // accidental tap
            try? FileManager.default.removeItem(at: current.url)
            phase = .idle
            return
        }
        sound("Pop")
        history.insert(Entry(id: current.id, date: current.started, audio: current.url.lastPathComponent, status: "transcribing", duration: duration), at: 0)
        if history.count > 200 { history.removeLast(history.count - 200) }
        saveHistory()
        phase = .transcribing
        process(current.id, paste: true)
    }

    // MARK: Pipeline

    private func process(_ id: String, paste: Bool) {
        guard let entry = history.first(where: { $0.id == id }) else { return }
        guard let key = apiKey else { return fail(id, "Add a Groq API key in Nook Settings") }
        let file = Self.dir.appendingPathComponent(entry.audio)
        let defaults = UserDefaults.standard
        let vocabulary = defaults.string(forKey: Keys.vocabulary) ?? ""
        let prompt = defaults.string(forKey: Keys.prompt) ?? Self.defaultPrompt
        let doCleanup = defaults.bool(forKey: Keys.cleanup)
        Task { @MainActor in
            do {
                let raw = try await Groq.transcribe(file: file, key: key, vocabulary: vocabulary)
                var text = raw
                if doCleanup, !raw.isEmpty {
                    text = (try? await Groq.cleanup(raw, key: key, systemPrompt: prompt, vocabulary: vocabulary)) ?? raw
                }
                update(id) { $0.raw = raw; $0.text = text; $0.status = "done"; $0.error = nil }
                if text.isEmpty {
                    phase = .idle
                    return
                }
                if paste { Self.paste(text) } else { Self.copy(text) }
                flash(.done)
            } catch {
                fail(id, error.localizedDescription)
            }
        }
    }

    private func fail(_ id: String, _ message: String) {
        update(id) { $0.status = "failed"; $0.error = message }
        sound("Basso")
        flash(.failed)
    }

    private func flash(_ phase: Phase) {
        self.phase = phase
        let work = DispatchWorkItem { [weak self] in if self?.phase == phase { self?.phase = .idle } }
        idleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (phase == .failed ? 4 : 1.5), execute: work)
    }

    private func update(_ id: String, _ change: (inout Entry) -> Void) {
        guard let i = history.firstIndex(where: { $0.id == id }) else { return }
        change(&history[i])
        saveHistory()
    }

    private func sound(_ name: String) {
        guard UserDefaults.standard.bool(forKey: Keys.sounds) else { return }
        NSSound(named: name)?.play()
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Put the text on the clipboard and press ⌘V in the frontmost app (FreeFlow keeps it in the clipboard too).
    static func paste(_ text: String) {
        copy(text)
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    // MARK: Storage

    private func loadHistory() {
        guard let data = try? Data(contentsOf: Self.historyURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        history = (try? decoder.decode([Entry].self, from: data)) ?? []
    }

    private func saveHistory() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(history) { try? data.write(to: Self.historyURL, options: .atomic) }
        PluginEvents.emit("dictation", historyPayload())
    }

    // MARK: Bridge

    func handle(_ fn: String, args: [Any], reply: @escaping (Any?, String?) -> Void) {
        let id = args.first as? String ?? ""
        let text = { self.history.first { $0.id == id }?.text ?? "" }
        switch fn {
        case "history": reply(historyPayload(), nil)
        case "state": reply(statePayload(), nil)
        case "toggle": toggle(); reply(statePayload(), nil)
        case "retry":
            update(id) { $0.status = "transcribing"; $0.error = nil }
            phase = .transcribing
            process(id, paste: false)
            reply(NSNull(), nil)
        case "copy": Self.copy(text()); reply(NSNull(), nil)
        case "paste":
            let t = text()
            // Let the click land and focus return to the previous app before pasting.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { Self.paste(t) }
            reply(NSNull(), nil)
        case "remove":
            if let entry = history.first(where: { $0.id == id }) { try? FileManager.default.removeItem(at: Self.dir.appendingPathComponent(entry.audio)) }
            history.removeAll { $0.id == id }
            saveHistory()
            reply(NSNull(), nil)
        case "clear":
            history.forEach { try? FileManager.default.removeItem(at: Self.dir.appendingPathComponent($0.audio)) }
            history = []
            saveHistory()
            reply(NSNull(), nil)
        default: reply(nil, "Unknown dictation call: \(fn)")
        }
    }

    func historyPayload() -> [[String: Any]] {
        let iso = ISO8601DateFormatter()
        return history.map {
            ["id": $0.id, "date": iso.string(from: $0.date), "status": $0.status, "text": $0.text ?? "",
             "raw": $0.raw ?? "", "error": $0.error ?? NSNull(), "duration": $0.duration]
        }
    }

    func statePayload() -> [String: Any] {
        ["recording": phase == .recording, "transcribing": phase == .transcribing,
         "holdShortcut": hotkeys.hold?.display ?? "Off", "toggleShortcut": hotkeys.toggle?.display ?? "Off", "hasKey": apiKey != nil,
         "accessibility": hotkeys.isTrusted]
    }
}
