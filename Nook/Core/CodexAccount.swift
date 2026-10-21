import Foundation

/// Transcription through the user's Codex login (~/.codex/auth.json), the same way BB does it:
/// ChatGPT login → chatgpt.com/backend-api/transcribe (model "gpt-transcribe");
/// API-key login → api.openai.com/v1/audio/transcriptions (gpt-4o-transcribe).
enum OpenAITranscriber {
    enum Auth {
        case chatgpt(accessToken: String, accountID: String)
        case apiKey(String)
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static var authURL: URL {
        let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        return codexHome.appendingPathComponent("auth.json")
    }

    static func readAuth() -> Auth? {
        guard let data = try? Data(contentsOf: authURL),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if let tokens = json["tokens"] as? [String: Any],
           let access = tokens["access_token"] as? String, !access.isEmpty,
           let account = tokens["account_id"] as? String, !account.isEmpty {
            return .chatgpt(accessToken: access, accountID: account)
        }
        if let key = json["OPENAI_API_KEY"] as? String, !key.isEmpty { return .apiKey(key) }
        return nil
    }

    /// For Settings: who we'd transcribe as.
    static var status: String {
        switch readAuth() {
        case .chatgpt: "Using your ChatGPT login from Codex"
        case .apiKey: "Using the OpenAI API key from Codex"
        case nil: "Not signed in — run `codex login` once"
        }
    }

}
