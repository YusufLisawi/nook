import SwiftUI

// MARK: Dictation

struct DictationPane: View {
    @AppStorage(DictationService.Keys.cleanup) private var cleanup = true
    @AppStorage(DictationService.Keys.sounds) private var sounds = true
    @AppStorage(DictationService.Keys.vocabulary) private var vocabulary = ""
    @AppStorage(DictationService.Keys.prompt) private var prompt = DictationService.defaultPrompt
    @AppStorage(DictationService.Keys.engine) private var engine = "chatgpt"
    @AppStorage(DictationService.Keys.micUID) private var micUID = ""
    @AppStorage(DictationService.Keys.keepAudioHours) private var keepAudioHours = 24.0
    @State private var mics = MicRecorder.microphones()

    var body: some View {
        Form {
            Section {
                LabeledContent("Hold to talk") {
                    SettingsShortcutRecorder(item: .dictation(hold: true))
                }
                LabeledContent("Toggle recording") {
                    SettingsShortcutRecorder(item: .dictation(hold: false))
                }
            } header: {
                Text("Shortcuts")
            } footer: {
                Text("Hold to Talk records while held. Toggle Recording starts on the first press and transcribes on the next. All shortcuts are also in Keyboard Shortcuts.")
            }
            Section {
                Picker("Microphone", selection: $micUID) {
                    Text("System default").tag("")
                    if !micUID.isEmpty, !mics.contains(where: { $0.id == micUID }) {
                        Text("Selected microphone (unavailable)").tag(micUID)
                    }
                    ForEach(mics) { Text($0.name).tag($0.id) }
                }
                Picker("Transcription", selection: $engine) {
                    Text("ChatGPT (Codex login)").tag("chatgpt")
                    Text("Groq Whisper").tag("groq")
                }
                Picker("Delete recordings after", selection: $keepAudioHours) {
                    Text("1 hour").tag(1.0)
                    Text("5 hours").tag(5.0)
                    Text("1 day").tag(24.0)
                    Text("1 week").tag(168.0)
                    Text("Never").tag(0.0)
                }
                .onChange(of: keepAudioHours) { _, _ in Services.shared.dictation.cleanupRecordings() }
                Toggle("Play recording sounds", isOn: $sounds)
            } header: {
                Text("Recording")
            } footer: {
                Text("Transcripts stay; only audio is deleted. Failed recordings are kept for a week so Retry works.")
            }
            Section {
                Toggle("Clean up text with AI (Groq)", isOn: $cleanup)
                TextField("Vocabulary (one per line)", text: $vocabulary, axis: .vertical).lineLimit(2...4)
                TextField("Clean-up prompt", text: $prompt, axis: .vertical).lineLimit(3...8)
            } header: {
                Text("Clean-up")
            } footer: {
                Text("Add names and specialist terms to help transcription. Clean-up uses the Groq key in ChatGPT & Codex.").font(.caption)
            }
        }
        .formStyle(.grouped)
        .onAppear { mics = MicRecorder.microphones() }
    }
}
