import AppKit
import SwiftUI

// Isolate the service from the app: these tests never construct Nook or use its support directory.
final class Services {
    static let shared = Services()
    static var supportDir: URL { fatalError("Tests must inject a support directory") }
    var pluginActivity: PluginActivity?
}
struct PluginActivity { var pluginID: String; var text: String; var symbol: String; var color: String }
enum CodexLink { static func cliPath() -> String? { nil } }
enum PluginRuntime { static func host(_ method: String, _ p: [String:Any]) {} }
struct AgentsPane: View { var body: some View { EmptyView() } }
enum PluginEvents {
    static var events: [[String: Any]] = []
    static func emit(_ event: String, _ payload: Any, to pluginID: String? = nil) { events.append(["event": event, "payload": payload]) }
}

@main struct AgentNativeTests {
    static func check(_ value: Bool, _ message: String) {
        if !value { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    static func wait(_ message: String, timeout: Double = 8, until predicate: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        check(predicate(), message)
    }
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let service = AgentService(root: root.appendingPathComponent("support"))
        let mock = root.appendingPathComponent("mock-codex")
        service.executable = { mock.path }
        var agent = NookAgent()
        agent.name = "Test agent"
        agent.instructions = "Review \"quotes\", /paths, backslashes \\ and\nnew lines 🦉"
        agent.workingDirectory = root.path
        agent = try service.save(agent)
        let defaults = try JSONDecoder().decode(NookAgent.self, from: Data("{}".utf8))
        check(defaults.fullAccess && defaults.model == "gpt-6.1-sol" && defaults.effort == "ultra", "Agent defaults")
        var args = try AgentCodexCommand.arguments(agent: agent, sessionID: "codex-id")
        check(args.contains("--dangerously-bypass-approvals-and-sandbox"), "Full access flag")
        check(args.suffix(3) == ["resume", "codex-id", "-"], "Exact resume syntax")
        check(args.firstIndex(of: "-C")! < args.firstIndex(of: "resume")!, "Resume inherits exec working folder")
        agent.fullAccess = false
        args = try AgentCodexCommand.arguments(agent: agent, sessionID: "codex-id")
        check(args.contains("workspace-write") && !args.contains("--dangerously-bypass-approvals-and-sandbox"), "Sandboxed resume")
        let firstText = "--literal 'quotes' $(touch forbidden) 🦉\nline two"
        let first = try service.handle("send", args: [agent.id, NSNull(), firstText]) as! [String: Any]
        let localID = first["id"] as! String
        wait("First turn completes") { service.sessions(agentID: agent.id).first?.status == "done" }
        var session = service.sessions(agentID: agent.id)[0]
        check(session.codexSessionId == "test-codex-thread", "Codex session id captured")
        check(session.usage["output_tokens"] == 12, "Usage preserved")
        let command = session.items.first { $0.payload["type"] as? String == "command_execution" }!
        check(command.payload["aggregated_output"] as? String == "hello 🦉\n", "Chunked UTF-8 JSONL and live output")
        check(command.payload["exit_code"] as? Int == 0, "Exit code parsed")
        check(session.items.contains { $0.payload["type"] as? String == "reasoning" }, "Reasoning parsed")
        check(session.items.contains { $0.payload["type"] as? String == "mcp_tool_call" }, "Structured MCP parsed")
        check(session.items.contains { $0.payload["type"] as? String == "web_search" }, "Web search parsed")
        check(session.items.contains { $0.payload["type"] as? String == "file_change" }, "File changes parsed")
        wait("File preview arrives") {
            service.sessions(agentID: agent.id)[0].items.contains { ($0.payload["diff"] as? String)?.contains("+A new file") == true }
        }
        check(try String(contentsOf: root.appendingPathComponent("last-prompt")) == firstText, "Prompt passed literally through stdin")
        _ = try service.handle("send", args: [agent.id, localID, "follow up"])
        wait("Follow-up completes") { service.sessions(agentID: agent.id).first?.status == "done" }
        session = service.sessions(agentID: agent.id)[0]
        check(session.items.filter { $0.payload["type"] as? String == "user_message" }.count == 2, "Follow-up keeps transcript")
        check(session.items.filter { $0.payload["type"] as? String == "agent_message" }.count == 2, "Turn-scoped IDs prevent resume collisions")
        let recorded = try String(contentsOf: root.appendingPathComponent("last-args"))
        check(recorded.contains("resume\ntest-codex-thread\n-"), "Follow-up uses real session id")
        let restored = AgentService(root: root.appendingPathComponent("support"))
        check(restored.agents.count == 1 && restored.sessions(agentID: agent.id).first?.items.count == session.items.count, "Agents and chats survive reload")
        let mode = root.appendingPathComponent("mode")
        try Data("error".utf8).write(to: mode)
        _ = try service.handle("send", args: [agent.id, localID, "fail"])
        wait("Failed turn finishes") { service.sessions(agentID: agent.id).first?.status == "error" }
        check(service.sessions(agentID: agent.id)[0].items.contains { $0.payload["message"] as? String == "Test failure" }, "Turn failure shown")
        try Data("wait".utf8).write(to: mode)
        _ = try service.handle("send", args: [agent.id, localID, "long-running"])
        wait("Descendant starts") { FileManager.default.fileExists(atPath: root.appendingPathComponent("child-pid").path) }
        let childPID = Int32(try String(contentsOf: root.appendingPathComponent("child-pid")).trimmingCharacters(in: .whitespacesAndNewlines))!
        do { _ = try service.handle("send", args: [agent.id, localID, "duplicate"]); check(false, "Concurrent turn rejected") } catch {}
        _ = try service.handle("cancel", args: [localID])
        wait("Cancel finishes") { service.sessions(agentID: agent.id).first?.status == "cancelled" }
        wait("Child process terminated") { kill(childPID, 0) != 0 }
        check(Services.shared.pluginActivity == nil, "Activity cleared after stop")
        let failedReload = AgentService(root: root.appendingPathComponent("support"))
        check(failedReload.sessions(agentID: agent.id).first?.status == "cancelled", "Cancellation persisted")
        let permissions = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("support/agents.json").path)
        check(permissions[.posixPermissions] as? Int == 0o600, "Private file permissions")
        let corrupt = root.appendingPathComponent("corrupt")
        try FileManager.default.createDirectory(at: corrupt, withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: corrupt.appendingPathComponent("agents.json"))
        let broken = AgentService(root: corrupt)
        do { _ = try broken.save(agent); check(false, "Corrupt data protected") } catch {}
        check(try String(contentsOf: corrupt.appendingPathComponent("agents.json")) == "broken", "Corrupt data never overwritten")
        service.shutdown()
        print("PASS: native agents, JSONL streaming, resume, persistence, errors and process-tree cancellation")
    }
}
