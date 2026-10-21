import SwiftUI

// MARK: ChatGPT & Codex

struct AIPane: View {
    @ObservedObject private var connection = SettingsSnapshots.codex
    @State private var testing = false
    @State private var testResult: (Bool, Double, String)?
    @State private var groqKey = ""
    @State private var openAIKey = ""
    @State private var keysLoaded = false
    @State private var launchingTerminal = false
    @State private var setupError: String?
    private var state: CodexLink.State { connection.value?.state ?? .notInstalled }
    private var path: String? { connection.value?.path }
    private var loaded: Bool { connection.value != nil }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: icon).font(.system(size: 26)).foregroundStyle(color)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(color.opacity(0.15)))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(loaded ? headline : "Checking ChatGPT connection…").font(.headline)
                        Text(loaded ? detail : "Reading your local Codex sign-in status.").font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 4)
            }
            Section {
                LabeledContent("Codex") {
                    if !loaded {
                        ProgressView().controlSize(.small)
                    } else if let path {
                        Label(path.replacingOccurrences(of: NSHomeDirectory(), with: "~"), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green).font(.callout)
                            .lineLimit(2).truncationMode(.middle).textSelection(.enabled).help(path)
                    } else {
                        Button("Install Codex") { beginSetup(install: true) }.disabled(launchingTerminal)
                    }
                }
                LabeledContent("ChatGPT account") {
                    switch state {
                    case let .ready(email):
                        Label(email ?? "Signed in", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green).font(.callout).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    case .apiKey:
                        Button("Sign in with ChatGPT instead") { beginSetup(install: false) }.disabled(launchingTerminal || path == nil)
                    default:
                        Button("Sign in with ChatGPT") { beginSetup(install: false) }.disabled(launchingTerminal || !loaded || path == nil)
                    }
                }
                if launchingTerminal { ProgressView("Opening Terminal…").controlSize(.small) }
                if let setupError {
                    Label(setupError, systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                LabeledContent("Connection") {
                    HStack(spacing: 8) {
                        if testing { ProgressView().controlSize(.small) }
                        Button("Test") {
                            testing = true
                            Task {
                                testResult = await CodexLink.test()
                                testing = false
                            }
                        }
                        .disabled(testing || !isReady)
                        Button("Refresh Status") { Task { await connection.refresh(force: true) } }
                            .disabled(connection.refreshing)
                        if connection.refreshing { ProgressView().controlSize(.small).accessibilityLabel("Refreshing connection") }
                    }
                }
                if let testResult {
                    Label(testResult.0 ? String(format: "Connected in %.1f seconds", testResult.1) : testResult.2,
                          systemImage: testResult.0 ? "checkmark.circle" : "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(testResult.0 ? .green : .red)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            } header: {
                Text("Setup")
            } footer: {
                Text("Nook uses your ChatGPT subscription the same way the Codex app does — through your Codex login. No API key, no extra cost. Install and sign-in open Terminal for one command.")
                    .font(.caption)
            }
            Section {
                SecureField("Groq API key", text: $groqKey)
                    .onChange(of: groqKey) { _, key in if keysLoaded { Secrets.set("groq_api_key", key.trimmingCharacters(in: .whitespaces)) } }
                SecureField("OpenAI API key", text: $openAIKey)
                    .onChange(of: openAIKey) { _, key in if keysLoaded { Secrets.set(AIBrain.openAISecret, key.trimmingCharacters(in: .whitespaces)) } }
            } header: {
                Text("Other providers (optional)")
            } footer: {
                Text("Pick them per command in AI Commands. Groq also powers dictation clean-up and nook.ai in plugins.").font(.caption)
            }
            .disabled(!keysLoaded)
        }
        .formStyle(.grouped)
        .task {
            async let status: Void = connection.refresh()
            let keys = await Task.detached(priority: .utility) {
                (Secrets.get("groq_api_key") ?? "", Secrets.get(AIBrain.openAISecret) ?? "")
            }.value
            groqKey = keys.0
            openAIKey = keys.1
            keysLoaded = true
            await status
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await connection.refresh(force: true) }
        }
    }

    @MainActor private func beginSetup(install: Bool) {
        launchingTerminal = true
        setupError = nil
        Task {
            setupError = install ? await CodexLink.install() : await CodexLink.signIn()
            launchingTerminal = false
        }
    }

    private var isReady: Bool { if case .ready = state { true } else { false } }
    private var icon: String { isReady ? "checkmark.seal.fill" : "link.badge.plus" }
    private var color: Color { isReady ? .green : .orange }
    private var headline: String {
        switch state {
        case .ready: "Connected to ChatGPT"
        case .apiKey: "Codex uses an API key"
        case .signedOut: "Codex is installed — sign in"
        case .notInstalled: "Connect your ChatGPT subscription"
        }
    }
    private var detail: String {
        switch state {
        case .ready: "AI Commands and dictation run on your subscription."
        case .apiKey: "Sign in with ChatGPT to use your subscription instead of paid API calls."
        case .signedOut: "One click opens Terminal with `codex login`."
        case .notInstalled: "Install Codex, then sign in with your ChatGPT account."
        }
    }
}
