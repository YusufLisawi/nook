import Foundation

func send(_ message: [String: Any]) {
    var object = message; object["jsonrpc"] = "2.0"
    guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
    data.append(10); try? FileHandle.standardOutput.write(contentsOf: data)
}
func host(_ method: String, _ params: [String: Any], id: String = "helper-1") {
    send(["id": id, "method": "host." + method, "params": params])
    // Correlate the host response by id in the loop; don't block a method handler waiting for it.
}
while let line = readLine() {
    guard line.utf8.count <= 1_048_576,
          let message = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
          message["jsonrpc"] as? String == "2.0", let method = message["method"] as? String, let id = message["id"] else { continue }
    if method == "hello" {
        let name = (message["params"] as? [String: Any])?["name"] as? String ?? "Nook"
        send(["id": id, "result": ["message": "Hello, \(name)!"]])
    } else { send(["id": id, "error": ["code": -32601, "message": "Unknown method"]]) }
}
