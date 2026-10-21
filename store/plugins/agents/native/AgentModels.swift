import Foundation

struct NookAgent: Codable, Identifiable, Equatable {
  var id = UUID().uuidString
  var name = "New agent"
  var instructions = ""
  var workingDirectory = "~"
  var model = "gpt-6.1-sol"
  var effort = "ultra"
  var fullAccess = true

  static let efforts = ["low", "medium", "high", "xhigh", "max", "ultra"]

  init() {}

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
    name = try c.decodeIfPresent(String.self, forKey: .name) ?? "New agent"
    instructions = try c.decodeIfPresent(String.self, forKey: .instructions) ?? ""
    workingDirectory = try c.decodeIfPresent(String.self, forKey: .workingDirectory) ?? "~"
    model = try c.decodeIfPresent(String.self, forKey: .model) ?? "gpt-6.1-sol"
    effort = try c.decodeIfPresent(String.self, forKey: .effort) ?? "ultra"
    fullAccess = try c.decodeIfPresent(Bool.self, forKey: .fullAccess) ?? true
  }

  var directory: String { (workingDirectory as NSString).expandingTildeInPath }
}

/// Keep the complete wire payload, including unfamiliar tools, without losing structured arguments/results.
struct AgentItem: Codable, Identifiable {
  var id: String
  var json: String

  init(id: String, payload: [String: Any]) {
    self.id = id
    json =
      (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
      .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
  }

  var payload: [String: Any] {
    var value = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    value["id"] = id
    return value
  }
}

struct AgentSession: Codable, Identifiable {
  var id = UUID().uuidString
  var agentId: String
  var title: String
  var codexSessionId: String?
  var createdAt = Date().timeIntervalSince1970
  var updatedAt = Date().timeIntervalSince1970
  var status = "idle"
  var revision = 0
  var items: [AgentItem] = []
  var usage: [String: Int] = [:]

  var summary: [String: Any] {
    [
      "id": id, "agentId": agentId, "title": title, "codexSessionId": codexSessionId ?? NSNull(),
      "createdAt": createdAt, "updatedAt": updatedAt, "status": status, "revision": revision,
      "usage": usage,
    ]
  }

  var payload: [String: Any] {
    summary.merging(["items": items.map(\.payload)]) { _, new in new }
  }
}

struct AgentFailure: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

enum AgentCodexCommand {
  /// Exec flags precede `resume`: 0.163's resume subcommand does not accept -C or -s itself.
  static func arguments(agent: NookAgent, sessionID: String?) throws -> [String] {
    let encoded = try JSONSerialization.data(
      withJSONObject: agent.instructions, options: [.fragmentsAllowed, .withoutEscapingSlashes])
    let instructions = String(decoding: encoded, as: UTF8.self)
    var args = [
      "exec", "--json", "--color", "never", "--skip-git-repo-check", "-m", agent.model,
      "-c", "model_reasoning_effort=\(agent.effort)", "-c",
      "developer_instructions=\(instructions)",
      "-C", agent.directory,
    ]
    args +=
      agent.fullAccess
      ? ["--dangerously-bypass-approvals-and-sandbox"]
      : ["-s", "workspace-write", "-c", "approval_policy=\"never\""]
    if let sessionID { args += ["resume", sessionID] }
    // Prompt goes through stdin, so leading dashes, quotes and long messages remain literal.
    return args + ["-"]
  }
}
