import Foundation

/// One way to ask an LLM, three backends:
/// - "codex": the user's ChatGPT subscription through their Codex login (same endpoint BB uses) — no API key
/// - "groq":  Groq API key (Settings → Dictation)
/// - "openai": OpenAI API key (Settings → AI)
enum AIBrain {
  struct Failure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }

  static let instructions =
    "You run a saved AI command. Follow the user's prompt exactly. Reply with only the resulting text — no preamble, no quotes, no commentary."

  static let codexModels = [
    ("gpt-6-luna", "GPT-6 Luna — fast"), ("gpt-6-astra", "GPT-6 Astra"),
    ("gpt-5.6-luna", "GPT-5.6 Luna"),
  ]
  static let groqModels = [
    ("openai/gpt-oss-120b", "GPT-OSS 120B"), ("openai/gpt-oss-20b", "GPT-OSS 20B"),
    ("llama-3.3-70b-versatile", "Llama 3.3 70B"),
  ]
  static let openAISecret = "openai_api_key"

  /// Providers + models for the command editor.
  static func providers() async -> [[String: Any]] {
    let codex = OpenAITranscriber.readAuth()
    var codexReady = false
    if case .chatgpt = codex { codexReady = true }
    let groq = Secrets.get("groq_api_key") != nil
    let openAIKey = Secrets.get(openAISecret)
    let openAIModels = await openAIModelList(key: openAIKey)
    return [
      [
        "id": "codex", "name": "ChatGPT (your Codex login)", "available": codexReady,
        "note": codexReady
          ? "Uses your ChatGPT subscription — no API key"
          : "Sign in to Codex (`codex login`) with ChatGPT",
        "models": codexModels.map { ["id": $0.0, "name": $0.1] },
      ],
      [
        "id": "groq", "name": "Groq", "available": groq,
        "note": groq ? "Groq API key" : "Add a Groq key in Settings → Dictation",
        "models": groqModels.map { ["id": $0.0, "name": $0.1] },
      ],
      [
        "id": "openai", "name": "OpenAI API", "available": openAIKey != nil,
        "note": openAIKey != nil ? "OpenAI API key" : "Add an OpenAI key in Settings → AI",
        "models": openAIModels.map { ["id": $0, "name": $0] },
      ],
    ]
  }

  /// Streams text through `onDelta` (Codex) and returns the full answer.
  static func complete(
    provider: String, model: String, effort: String, prompt: String,
    onDelta: @escaping (String) -> Void
  ) async throws -> String {
    switch provider {
    case "groq":
      guard let key = Secrets.get("groq_api_key") else {
        throw Failure(message: "Add a Groq API key in Settings → Dictation")
      }
      let text = try await chat(
        url: "https://api.groq.com/openai/v1/chat/completions", key: key, model: model,
        effort: effort, prompt: prompt)
      onDelta(text)
      return text
    case "openai":
      guard let key = Secrets.get(openAISecret) else {
        throw Failure(message: "Add an OpenAI API key in Settings → AI")
      }
      let text = try await chat(
        url: "https://api.openai.com/v1/chat/completions", key: key, model: model, effort: effort,
        prompt: prompt)
      onDelta(text)
      return text
    default:
      return try await codex(model: model, effort: effort, prompt: prompt, onDelta: onDelta)
    }
  }

  // MARK: Codex (ChatGPT subscription)

  private static func codex(
    model: String, effort: String, prompt: String, onDelta: @escaping (String) -> Void
  ) async throws -> String {
    guard case .chatgpt(let token, let account) = OpenAITranscriber.readAuth() else {
      throw Failure(
        message:
          "Sign in to Codex with your ChatGPT account (`codex login`), or pick another provider")
    }
    var request = URLRequest(
      url: URL(string: "https://chatgpt.com/backend-api/codex/responses")!, timeoutInterval: 120)
    request.httpMethod = "POST"
    for (key, value) in [
      "Authorization": "Bearer \(token)", "chatgpt-account-id": account, "originator": "nook",
      "OpenAI-Beta": "responses=experimental", "Accept": "text/event-stream",
      "Content-Type": "application/json",
    ] {
      request.setValue(value, forHTTPHeaderField: key)
    }
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "model": model, "instructions": instructions, "reasoning": ["effort": effort],
      "store": false, "stream": true,
      "input": [["role": "user", "content": [["type": "input_text", "text": prompt]]]],
    ])
    let (bytes, response) = try await URLSession.shared.bytes(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard status == 200 else {
      var body = ""
      for try await line in bytes.lines {
        body += line
        if body.count > 2000 { break }
      }
      let detail =
        ((try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any])?["detail"]
        as? String
      if status == 401 {
        throw Failure(message: "Codex login expired — open Codex once (or run `codex login`)")
      }
      throw Failure(message: detail ?? "ChatGPT returned HTTP \(status)")
    }
    var text = ""
    for try await line in bytes.lines where line.hasPrefix("data: ") {
      guard
        let event = (try? JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8)))
          as? [String: Any]
      else { continue }
      switch event["type"] as? String {
      case "response.output_text.delta":
        let delta = event["delta"] as? String ?? ""
        text += delta
        onDelta(text)
      case "response.failed", "error":
        let message =
          ((event["response"] as? [String: Any])?["error"] as? [String: Any])?["message"] as? String
          ?? event["message"] as? String ?? "ChatGPT couldn't answer"
        throw Failure(message: message)
      case "response.completed", "response.done":
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
      default:
        break
      }
    }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  // MARK: OpenAI-compatible chat (Groq, OpenAI)

  private static func chat(url: String, key: String, model: String, effort: String, prompt: String)
    async throws -> String
  {
    var request = URLRequest(url: URL(string: url)!, timeoutInterval: 90)
    request.httpMethod = "POST"
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    var body: [String: Any] = [
      "model": model,
      "messages": [
        ["role": "system", "content": instructions], ["role": "user", "content": prompt],
      ],
    ]
    if model.contains("gpt-oss") || model.hasPrefix("o") || model.hasPrefix("gpt-5") {
      if effort != "none" { body["reasoning_effort"] = effort }
    } else {
      body["temperature"] = 0.3
    }
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    let (data, response) = try await URLSession.shared.data(for: request)
    let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
      throw Failure(
        message: (json["error"] as? [String: Any])?["message"] as? String ?? "AI request failed")
    }
    let text =
      ((json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"]
      as? String ?? ""
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static var cachedOpenAIModels: [String]?

  private static func openAIModelList(key: String?) async -> [String] {
    guard let key else { return [] }
    if let cachedOpenAIModels { return cachedOpenAIModels }
    var request = URLRequest(
      url: URL(string: "https://api.openai.com/v1/models")!, timeoutInterval: 10)
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    guard let (data, _) = try? await URLSession.shared.data(for: request),
      let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      let list = json["data"] as? [[String: Any]]
    else { return [] }
    let ids = list.compactMap { $0["id"] as? String }
      .filter {
        ($0.hasPrefix("gpt-") || $0.hasPrefix("o")) && !$0.contains("audio")
          && !$0.contains("realtime") && !$0.contains("tts") && !$0.contains("transcribe")
      }
      .sorted()
    cachedOpenAIModels = ids
    return ids
  }
}
