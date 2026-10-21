import Foundation

/// Generic AI routing; provider code is delivered by the Commands Store helper.
enum AIBrain {
  static let openAISecret = "openai_api_key"
  static func complete(
    provider: String, model: String, effort: String, prompt: String,
    onDelta: @escaping (String) -> Void
  ) async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.main.async {
        let requestID = UUID().uuidString
        let observer = NotificationCenter.default.addObserver(
          forName: .nookPluginEvent, object: nil, queue: .main
        ) { note in
          guard note.userInfo?["event"] as? String == "native:aiDelta",
            let payload = note.userInfo?["payload"] as? [String: Any],
            payload["requestID"] as? String == requestID, let text = payload["text"] as? String
          else { return }
          onDelta(text)
        }
        PluginEngine.shared.webCall(
          id: "commands", method: "native.call",
          args: [
            "ai.complete",
            [
              "provider": provider, "model": model, "effort": effort, "prompt": prompt,
              "requestID": requestID,
            ],
          ], vm: nil
        ) { value, error in
          NotificationCenter.default.removeObserver(observer)
          if let error {
            continuation.resume(throwing: PluginEngineError(error))
          } else {
            let text = value as? String ?? ""
            onDelta(text)
            continuation.resume(returning: text)
          }
        }
      }
    }
  }
}
