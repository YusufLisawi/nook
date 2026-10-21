import Foundation

/// Preserve large saved chats/tool snapshots without raising the engine's 1 MiB frame limit.
enum AgentTransport {
  private static let maximum = 32 * 1024 * 1024
  private static let chunkSize = 384 * 1024
  private static let lock = NSLock()
  private static var transfers: [String: (Data, Date)] = [:]

  static func reference(_ value: Any) -> [String: Any]? {
    guard
      let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
      data.count <= maximum
    else { return nil }
    lock.lock()
    defer { lock.unlock() }
    transfers = transfers.filter { Date().timeIntervalSince($0.value.1) < 60 }
    guard transfers.count < 4 else { return nil }
    let token = UUID().uuidString
    transfers[token] = (data, Date())
    return ["__nookTransfer": token, "chunks": (data.count + chunkSize - 1) / chunkSize]
  }
  static func handle(_ method: String, _ params: [String: Any], reply: BridgeRegistry.Reply) -> Bool
  {
    guard method == "transport.read" || method == "transport.release" else { return false }
    lock.lock()
    defer { lock.unlock() }
    let token = params["token"] as? String ?? ""
    guard let (data, date) = transfers[token], Date().timeIntervalSince(date) < 60 else {
      reply(nil, "Chat transfer expired. Reopen the chat.")
      return true
    }
    if method == "transport.release" {
      transfers.removeValue(forKey: token)
      reply(NSNull(), nil)
      return true
    }
    let index = params["index"] as? Int ?? -1
    guard index >= 0, index < (data.count + chunkSize - 1) / chunkSize else {
      reply(nil, "Invalid transfer chunk.")
      return true
    }
    let start = index * chunkSize
    reply(data.subdata(in: start..<min(data.count, start + chunkSize)).base64EncodedString(), nil)
    return true
  }
  static func emit(_ event: String, _ value: Any) -> Bool {
    guard
      let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
      data.count > chunkSize
    else { return false }
    guard data.count <= maximum else {
      PluginEvents.send([
        "jsonrpc": "2.0", "method": "agentStorageError",
        "params":
          "This chat update exceeds 32 MiB. Start a new chat; saved history remains intact.",
      ])
      return true
    }
    let token = UUID().uuidString
    let count = (data.count + chunkSize - 1) / chunkSize
    for index in 0..<count {
      let start = index * chunkSize
      PluginEvents.send([
        "jsonrpc": "2.0", "method": "transport.event",
        "params": [
          "token": token, "event": event, "index": index, "count": count,
          "data": data.subdata(in: start..<min(data.count, start + chunkSize))
            .base64EncodedString(),
        ],
      ])
    }
    return true
  }
}
