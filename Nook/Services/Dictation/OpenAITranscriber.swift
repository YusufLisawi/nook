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

    static func transcribe(file: URL, hint: String) async throws -> String {
        guard let auth = readAuth() else { throw Failure(message: "Sign in to Codex first (run `codex login`), or switch the engine to Groq") }
        var request: URLRequest
        let model: String
        switch auth {
        case let .chatgpt(token, account):
            request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/transcribe")!, timeoutInterval: 60)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(account, forHTTPHeaderField: "chatgpt-account-id")
            request.setValue("nook", forHTTPHeaderField: "originator")
            model = "gpt-transcribe"
        case let .apiKey(key):
            request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!, timeoutInterval: 60)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            model = "gpt-4o-transcribe"
        }
        request.httpMethod = "POST"
        let boundary = "nook-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        func field(_ name: String, _ value: String) {
            body += Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8)
        }
        field("model", model)
        if !hint.isEmpty { field("prompt", hint) }
        body += Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(file.lastPathComponent)\"\r\nContent-Type: audio/wav\r\n\r\n".utf8)
        body += try Data(contentsOf: file)
        body += Data("\r\n--\(boundary)--\r\n".utf8)
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        switch status {
        case 200:
            return (json["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        case 401:
            throw Failure(message: "Codex login expired — open Codex once (or run `codex login`) and retry")
        case 403 where json.isEmpty:
            throw Failure(message: "ChatGPT blocked the request (403). Try again, or switch the engine to Groq")
        default:
            let message = (json["error"] as? [String: Any])?["message"] as? String ?? (json["detail"] as? String) ?? "HTTP \(status)"
            throw Failure(message: "Transcription failed: \(message)")
        }
    }
}
