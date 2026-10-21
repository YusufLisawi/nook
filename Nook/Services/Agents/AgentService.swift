import AppKit
import SwiftUI

/// Main-thread confined. Codex owns tool execution and its conversation context; Nook owns the rendered history.
final class AgentService: ObservableObject {
    private static var instance: AgentService?
    static var shared: AgentService {
        if let instance { return instance }
        let value = AgentService(root: Services.supportDir); instance = value; return value
    }
    @Published private(set) var agents: [NookAgent] = []
    @Published private(set) var storageError: String?
    private var chats: [String: AgentSession] = [:]
    private var runs: [String: AgentRun] = [:]
    private let root: URL
    private var pendingSave: DispatchWorkItem?
    private var terminationObserver: NSObjectProtocol?
    private var dirty = Set<String>()
    // Injectable for tests: production uses the same login-shell discovery as ChatGPT & Codex Settings.
    var executable: () -> String? = { CodexLink.cliPath() }

    init(root: URL) {
        self.root = root
        do {
            let file = root.appendingPathComponent("agents.json")
            if FileManager.default.fileExists(atPath: file.path) {
                agents = try JSONDecoder().decode([NookAgent].self, from: Data(contentsOf: file))
            }
            let folders = (try? FileManager.default.contentsOfDirectory(at: sessionsRoot, includingPropertiesForKeys: nil)) ?? []
            for folder in folders {
                let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
                for file in files where file.pathExtension == "json" {
                    var session = try JSONDecoder().decode(AgentSession.self, from: Data(contentsOf: file))
                    guard UUID(uuidString: session.id) != nil, UUID(uuidString: session.agentId) != nil else { continue }
                    if session.status == "running" || session.status == "stopping" {
                        session.status = "interrupted"
                        Self.finishItems(&session, status: "interrupted")
                    }
                    chats[session.id] = session
                }
            }
        } catch {
            storageError = "Couldn't read saved agents or chats: \(error.localizedDescription). Check the Nook support folder before saving."
        }
    }

    private var sessionsRoot: URL { root.appendingPathComponent("AgentSessions", isDirectory: true) }
    private func folder(_ id: String) -> URL { sessionsRoot.appendingPathComponent(id, isDirectory: true) }

    static func disable() {
        guard let value = instance else { return }
        value.shutdown()
        if let observer = value.terminationObserver { NotificationCenter.default.removeObserver(observer) }
        value.terminationObserver = nil
        value.pendingSave?.cancel(); value.pendingSave = nil
        value.chats.removeAll(); value.agents.removeAll()
        BridgeRegistry.unregister("agents")
        instance = nil
    }

    static func register() {
        let service = shared
        BridgeRegistry.register("agents", functions: ["list", "save", "remove", "sessions", "open", "send", "cancel", "models"]) { fn, args, _, reply in
            do { reply(try service.handle(fn, args: args), nil) }
            catch { reply(nil, error.localizedDescription) }
        }
        SettingsRegistry.register(id: "agents", title: "Agents", symbol: "person.2.wave.2.fill", tint: .orange, order: 17) { AgentsPane() }
        service.terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                                            object: nil, queue: .main) { _ in service.shutdown() }
    }

    func handle(_ fn: String, args: [Any]) throws -> Any {
        let id = args.first as? String ?? ""
        switch fn {
        case "list":
            if let storageError { throw AgentFailure(message: storageError) }
            return try agents.map { try Self.dictionary($0) }
        case "save":
            guard let value = args.first as? [String: Any] else { throw AgentFailure(message: "Pass an agent to save.") }
            let agent = try JSONDecoder().decode(NookAgent.self, from: JSONSerialization.data(withJSONObject: value))
            return try Self.dictionary(save(agent))
        case "remove": try remove(id); return NSNull()
        case "sessions": return sessions(agentID: id).map(\.summary)
        case "open":
            guard let session = chats[id] else { throw AgentFailure(message: "This chat is no longer available.") }
            return session.payload
        case "send":
            let sessionID = args.count > 1 ? args[1] as? String : nil
            let text = args.count > 2 ? args[2] as? String ?? "" : ""
            return try send(agentID: id, sessionID: sessionID, text: text).payload
        case "cancel": try cancel(id); return NSNull()
        case "models": return Self.models().map { ["id": $0.id, "name": $0.name] }
        default: throw AgentFailure(message: "Unknown agents call: \(fn)")
        }
    }

    @discardableResult
    func save(_ proposed: NookAgent) throws -> NookAgent {
        try writable()
        var agent = proposed
        guard UUID(uuidString: agent.id) != nil else { throw AgentFailure(message: "Invalid agent ID.") }
        agent.name = agent.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if agent.name.isEmpty { agent.name = "New agent" }
        if agent.workingDirectory.isEmpty { agent.workingDirectory = "~" }
        guard agent.directory.hasPrefix("/"), !agent.directory.contains("\0") else { throw AgentFailure(message: "Choose an absolute working folder, or a path starting with ~.") }
        guard !agent.model.isEmpty, NookAgent.efforts.contains(agent.effort) else { throw AgentFailure(message: "Choose a model and reasoning level.") }
        var updated = agents
        if let index = updated.firstIndex(where: { $0.id == agent.id }) { updated[index] = agent } else { updated.append(agent) }
        try write(updated, to: root.appendingPathComponent("agents.json"))
        agents = updated
        PluginEvents.emit("agents", try updated.map { try Self.dictionary($0) }, to: "agents")
        return agent
    }

    func remove(_ id: String) throws {
        try writable()
        guard agents.contains(where: { $0.id == id }) else { return }
        guard !runs.values.contains(where: { $0.agentID == id }) else { throw AgentFailure(message: "Stop this agent's running chats before deleting it.") }
        let updated = agents.filter { $0.id != id }
        // Trash the agent's history, preserving a way back for user files.
        let directory = folder(id)
        var trashed: NSURL?
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.trashItem(at: directory, resultingItemURL: &trashed) }
        do { try write(updated, to: root.appendingPathComponent("agents.json")) }
        catch {
            if let trashed { try? FileManager.default.moveItem(at: trashed as URL, to: directory) }
            throw error
        }
        agents = updated
        chats = chats.filter { $0.value.agentId != id }
        PluginEvents.emit("agents", try updated.map { try Self.dictionary($0) }, to: "agents")
    }

    func sessions(agentID: String) -> [AgentSession] {
        chats.values.filter { $0.agentId == agentID }.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func send(agentID: String, sessionID: String?, text: String) throws -> AgentSession {
        try writable()
        guard let agent = agents.first(where: { $0.id == agentID }) else { throw AgentFailure(message: "Choose or create an agent first.") }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AgentFailure(message: "Write a message first.") }
        guard text.utf8.count <= 1_000_000 else { throw AgentFailure(message: "This message is too long. Keep it under 1 MB.") }
        guard let path = executable() else { throw AgentFailure(message: "Install Codex and run codex login, or open Settings → ChatGPT & Codex.") }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: agent.directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw AgentFailure(message: "The working folder doesn't exist. Choose a folder in Settings → Agents.")
        }
        var session: AgentSession
        if let sessionID {
            guard let saved = chats[sessionID], saved.agentId == agentID else { throw AgentFailure(message: "This chat belongs to another agent or is unavailable.") }
            guard runs[sessionID] == nil else { throw AgentFailure(message: "Wait for this turn to finish, or stop it first.") }
            guard saved.codexSessionId != nil else { throw AgentFailure(message: "Codex didn't create a resumable session. Start a new chat.") }
            session = saved
        } else {
            session = AgentSession(agentId: agentID, title: String(text.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(64)))
        }
        let turnID = UUID().uuidString
        session.items.append(AgentItem(id: turnID + ":user", payload: ["type": "user_message", "text": text]))
        session.status = "running"
        session.updatedAt = Date().timeIntervalSince1970
        session.revision += 1
        // Fail before starting tools if history cannot be persisted.
        try persist(session)
        chats[session.id] = session
        let run = AgentRun(agentID: agentID, turnID: turnID)
        runs[session.id] = run
        let localID = session.id
        do {
            try run.process.start(executable: path, arguments: AgentCodexCommand.arguments(agent: agent, sessionID: session.codexSessionId),
                                  directory: agent.directory, prompt: text,
                                  onLine: { [weak self] line in self?.receive(line, sessionID: localID, run: run, directory: agent.directory) },
                                  onExit: { [weak self] code, diagnostic in self?.finish(localID, run: run, code: code, diagnostic: diagnostic) })
        } catch {
            runs.removeValue(forKey: localID)
            session.status = "error"
            session.items.append(AgentItem(id: turnID + ":launch", payload: ["type": "error", "message": error.localizedDescription]))
            session.revision += 1
            chats[localID] = session
            try persist(session)
            emit(session)
            throw error
        }
        emit(session)
        updateActivity()
        return session
    }

    private func receive(_ line: Data, sessionID: String, run: AgentRun, directory: String) {
        guard runs[sessionID] === run, !run.cancelled, var session = chats[sessionID] else { return }
        guard let event = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], let type = event["type"] as? String else {
            if !line.isEmpty { upsert(["type": "error", "message": "Unrecognized Codex output: " + String(decoding: line.prefix(2000), as: UTF8.self)],
                                     id: run.turnID + ":parse:" + UUID().uuidString, in: &session) }
            session.revision += 1
            chats[sessionID] = session
            queueSave(sessionID)
            emit(session)
            return
        }
        var changed: AgentItem?
        switch type {
        case "thread.started": session.codexSessionId = event["thread_id"] as? String
        case "item.started", "item.updated", "item.completed":
            if var item = event["item"] as? [String: Any] {
                let id = run.turnID + ":" + (item["id"] as? String ?? UUID().uuidString)
                if item["status"] == nil { item["status"] = type == "item.completed" ? "completed" : "in_progress" }
                changed = upsert(item, id: id, in: &session)
                if item["type"] as? String == "file_change", type == "item.completed" {
                    AgentDiff.preview(changes: item["changes"] as? [[String: Any]] ?? [], directory: directory) { [weak self] preview in
                        guard let self, var latest = self.chats[sessionID], let index = latest.items.firstIndex(where: { $0.id == id }) else { return }
                        var payload = latest.items[index].payload
                        payload["diff"] = preview
                        let updated = self.upsert(payload, id: id, in: &latest)
                        latest.revision += 1
                        self.chats[sessionID] = latest
                        self.queueSave(sessionID)
                        self.emit(latest, item: updated)
                    }
                }
            }
        case "turn.completed":
            run.completed = true
            session.usage = event["usage"] as? [String: Int] ?? [:]
        case "turn.failed", "error":
            run.failed = true
            let message = (event["error"] as? [String: Any])?["message"] as? String ?? event["message"] as? String ?? "Codex couldn't complete this turn."
            changed = upsert(["type": "error", "message": message], id: run.turnID + ":error:" + UUID().uuidString, in: &session)
        default: break
        }
        session.updatedAt = Date().timeIntervalSince1970
        session.revision += 1
        chats[sessionID] = session
        queueSave(sessionID)
        emit(session, item: changed)
    }

    @discardableResult
    private func upsert(_ payload: [String: Any], id: String, in session: inout AgentSession) -> AgentItem {
        let item = AgentItem(id: id, payload: payload)
        if let index = session.items.firstIndex(where: { $0.id == id }) { session.items[index] = item } else { session.items.append(item) }
        return item
    }

    private func finish(_ id: String, run: AgentRun, code: Int32, diagnostic: String) {
        guard runs[id] === run, var session = chats[id] else { return }
        runs.removeValue(forKey: id)
        session.status = run.cancelled ? "cancelled" : (code == 0 && run.completed && !run.failed ? "done" : "error")
        if session.status == "error", !run.failed {
            let detail = diagnostic.trimmingCharacters(in: .whitespacesAndNewlines)
            session.items.append(AgentItem(id: run.turnID + ":exit", payload: ["type": "error", "message": detail.isEmpty ? "Codex exited (\(code)) before completing the turn. Check codex login, model access and agent settings." : String(detail.suffix(4000))]))
        }
        Self.finishItems(&session, status: session.status == "done" ? "completed" : session.status)
        session.revision += 1
        session.updatedAt = Date().timeIntervalSince1970
        chats[id] = session
        queueSave(id)
        flush()
        emit(session)
        updateActivity()
    }

    private static func finishItems(_ session: inout AgentSession, status: String) {
        for index in session.items.indices {
            var item = session.items[index].payload
            if item["status"] as? String == "in_progress" {
                item["status"] = status
                session.items[index] = AgentItem(id: session.items[index].id, payload: item)
            }
        }
    }

    private func cancel(_ id: String) throws {
        guard let run = runs[id] else { return }
        run.cancelled = true
        if var session = chats[id] {
            session.status = "stopping"
            session.revision += 1
            chats[id] = session
            queueSave(id)
            emit(session)
        }
        run.process.cancel()
    }

    func shutdown() {
        for id in Array(runs.keys) { try? cancel(id) }
        flush()
    }

    private func updateActivity() {
        let name = runs.values.first.flatMap { run in agents.first { $0.id == run.agentID }?.name }
        if let name {
            Services.shared.pluginActivity = PluginActivity(pluginID: "agents", text: String(name.prefix(11)) + "…", symbol: "sparkles", color: "#ff9f0a")
        } else if Services.shared.pluginActivity?.pluginID == "agents" { Services.shared.pluginActivity = nil }
    }

    private func emit(_ session: AgentSession, item: AgentItem? = nil) {
        var payload: [String: Any] = ["session": item == nil ? session.payload : session.summary]
        if let item { payload["item"] = item.payload }
        PluginEvents.emit("agentSession", payload, to: "agents")
    }

    private func writable() throws { if let storageError { throw AgentFailure(message: storageError) } }
    private func persist(_ session: AgentSession) throws { try write(session, to: folder(session.agentId).appendingPathComponent(session.id + ".json")) }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func queueSave(_ id: String) {
        dirty.insert(id)
        guard pendingSave == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        for id in Array(dirty) {
            guard let session = chats[id] else { dirty.remove(id); continue }
            do { try persist(session); dirty.remove(id) }
            catch {
                storageError = "Couldn't save chat history: \(error.localizedDescription)"
                PluginEvents.emit("agentStorageError", storageError ?? "Couldn't save chat history.", to: "agents")
            }
        }
    }

    private static func dictionary<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }

    struct Model: Identifiable { let id: String; let name: String }
    static func models() -> [Model] {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex"
        if let data = try? Data(contentsOf: URL(fileURLWithPath: home).appendingPathComponent("models_cache.json")),
           let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let list = json["models"] as? [[String: Any]] {
            var seen = Set<String>()
            let models = list.compactMap { item -> Model? in
                guard let id = item["slug"] as? String, seen.insert(id).inserted, item["visibility"] as? String != "hide" else { return nil }
                return Model(id: id, name: item["display_name"] as? String ?? id)
            }
            if !models.isEmpty { return models }
        }
        return [Model(id: "gpt-6.1-sol", name: "GPT-6.1 Sol"), Model(id: "gpt-6-astra", name: "GPT-6 Astra"), Model(id: "gpt-6-luna", name: "GPT-6 Luna")]
    }
}

private final class AgentRun {
    let agentID: String
    let turnID: String
    let process = AgentProcess()
    var cancelled = false
    var completed = false
    var failed = false
    init(agentID: String, turnID: String) { self.agentID = agentID; self.turnID = turnID }
}
