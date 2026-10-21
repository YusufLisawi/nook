import CoreFoundation
import Foundation

/// JSON-RPC 2.0, one UTF-8 object per LF (CRLF accepted). Limits apply per frame, not per read.
struct PluginRPCFramer {
    static let maximum = 1_048_576
    private var buffer = Data()
    mutating func append(_ data: Data) throws -> [[String: Any]] {
        buffer.append(data)
        var result: [[String: Any]] = []
        while let end = buffer.firstIndex(of: 10) {
            let frame = buffer.prefix(upTo: end)
            guard frame.count <= Self.maximum else { throw PluginEngineError("RPC frame exceeds 1 MiB.") }
            buffer.removeSubrange(...end)
            if frame.allSatisfy({ $0 == 13 || $0 == 32 || $0 == 9 }) { continue }
            guard let object = try JSONSerialization.jsonObject(with: frame) as? [String: Any] else { throw PluginEngineError("Expected a JSON-RPC object on stdout; send logs to stderr.") }
            try Self.validate(object)
            result.append(object)
        }
        guard buffer.count <= Self.maximum else { throw PluginEngineError("Unterminated RPC frame exceeds 1 MiB.") }
        return result
    }
    static func encode(_ object: [String: Any]) throws -> Data {
        try validate(object)
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed])
        guard data.count <= maximum else { throw PluginEngineError("RPC frame exceeds 1 MiB.") }
        data.append(10); return data
    }
    private static func validate(_ object: [String: Any]) throws {
        guard object["jsonrpc"] as? String == "2.0" else { throw PluginEngineError("Expected JSON-RPC 2.0.") }
        if let id = object["id"] {
            let number = id as? NSNumber
            guard id is String || (number != nil && CFGetTypeID(number!) != CFBooleanGetTypeID()) else { throw PluginEngineError("RPC ids must be strings or numbers.") }
        }
        if let method = object["method"] {
            guard let method = method as? String, !method.isEmpty, object["result"] == nil, object["error"] == nil else { throw PluginEngineError("Invalid RPC request.") }
            if let params = object["params"], !(params is [String: Any]) && !(params is [Any]) { throw PluginEngineError("RPC params must be an object or array.") }
        } else {
            guard object["id"] != nil, (object["result"] != nil) != (object["error"] != nil) else { throw PluginEngineError("Invalid RPC response.") }
            if let error = object["error"] {
                guard let error = error as? [String: Any], let code = error["code"] as? NSNumber,
                      CFGetTypeID(code) != CFBooleanGetTypeID(), code.doubleValue == Double(code.intValue), error["message"] is String else { throw PluginEngineError("Invalid RPC error object.") }
            }
        }
    }
}

struct PluginRestartBackoff {
    private(set) var failures = 0
    mutating func reset() { failures = 0 }
    mutating func next(uptime: TimeInterval) -> TimeInterval {
        if uptime >= 60 { failures = 0 }
        let delay = min(60, pow(2, Double(min(failures, 6))))
        failures += 1
        return delay
    }
}
