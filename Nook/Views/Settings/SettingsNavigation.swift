import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, tabs, commands, ai, dictation, shortcuts, updates, tools, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .tabs: "Tabs & Plugins"
        case .commands: "AI Commands"
        case .ai: "ChatGPT & Codex"
        case .dictation: "Dictation"
        case .shortcuts: "Keyboard Shortcuts"
        case .updates: "Updates"
        case .tools: "Command Line"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .tabs: "square.grid.2x2.fill"
        case .commands: "wand.and.stars"
        case .ai: "sparkles"
        case .dictation: "waveform"
        case .shortcuts: "keyboard.fill"
        case .updates: "arrow.down.circle.fill"
        case .tools: "terminal.fill"
        case .about: "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general, .shortcuts: .gray
        case .tabs: .blue
        case .commands: .orange
        case .ai: .green
        case .dictation: .red
        case .updates: .indigo
        case .tools: .brown
        case .about: .blue
        }
    }

    var keywords: [String] {
        switch self {
        case .general: ["notch", "hover", "click", "screen", "display", "fullscreen", "haptic", "swipe", "shelf", "drag", "music", "timer", "login", "startup"]
        case .tabs: ["plugin", "enable", "disable", "order", "dock", "height", "shortcut", "hotkey", "customize", "code", "revert", "reload"]
        case .commands: ["prompt", "selection", "clipboard", "output", "provider", "model", "reasoning", "hotkey", "shortcut", "translate"]
        case .ai: ["account", "login", "subscription", "connection", "Groq", "OpenAI", "API key", "provider"]
        case .dictation: ["voice", "microphone", "record", "transcription", "Whisper", "sound", "vocabulary", "cleanup", "audio", "hold to talk", "shortcut", "retention"]
        case .shortcuts: ["keyboard", "hotkey", "conflict", "record", "accessibility", "tab", "command", "dictation"]
        case .updates: ["version", "automatic", "download", "install", "check"]
        case .tools: ["CLI", "terminal", "PATH", "install", "skill", "agent", "Claude", "Codex"]
        case .about: ["version", "build", "website", "GitHub", "license", "MIT", "update"]
        }
    }
}

enum SettingsSearch {
    /// Every word must match; accents and case don't affect search.
    static func matches(_ query: String, in terms: [String]) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace)
        let text = terms.joined(separator: " ")
        return words.allSatisfy { text.range(of: String($0), options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}

final class SettingsRouter: ObservableObject {
    static let shared = SettingsRouter()
    static let lastPaneKey = "settingsLastPane"
    @Published var pane: String? = UserDefaults.standard.string(forKey: lastPaneKey) ?? SettingsPane.general.rawValue {
        didSet { if let pane { UserDefaults.standard.set(pane, forKey: Self.lastPaneKey) } }
    }

    static func isKnown(_ id: String) -> Bool {
        SettingsPane(rawValue: id) != nil || SettingsRegistry.panes.contains { $0.id == id }
    }
}
