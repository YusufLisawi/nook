import AppKit
import SwiftUI

/// A JSON scalar (manifest defaults + saved values).
enum JSONValue: Codable, Equatable, Sendable {
    case bool(Bool), number(Double), string(String), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else { self = .string(try c.decode(String.self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case let .bool(b): try c.encode(b)
        case let .number(n): try c.encode(n)
        case let .string(s): try c.encode(s)
        case .null: try c.encodeNil()
        }
    }

    var any: Any {
        switch self {
        case let .bool(b): b
        case let .number(n): n
        case let .string(s): s
        case .null: NSNull()
        }
    }

    init(any: Any?) {
        switch any {
        case let b as Bool: self = .bool(b)
        case let n as NSNumber: self = .number(n.doubleValue)
        case let s as String: self = .string(s)
        default: self = .null
        }
    }

    var bool: Bool { if case let .bool(b) = self { b } else { false } }
    var number: Double { if case let .number(n) = self { n } else { 0 } }
    var string: String {
        switch self {
        case let .string(s): s
        case let .number(n): n == n.rounded() ? String(Int(n)) : String(n)
        case let .bool(b): String(b)
        case .null: ""
        }
    }
}

/// One option a plugin declares in plugin.json → `"settings": [...]`. Nook renders the form; the plugin reads values.
struct PluginSetting: Decodable, Identifiable, Equatable {
    enum Kind: String, Decodable { case toggle, text, secret, textarea, number, select, color }

    var key: String
    var label: String
    var type: Kind
    var help: String?
    var options: [String]?
    var min: Double?
    var max: Double?
    var step: Double?
    var `default`: JSONValue?

    var id: String { key }

    var fallback: JSONValue {
        if let d = self.default { return d }
        switch type {
        case .toggle: return .bool(false)
        case .number: return .number(min ?? 0)
        case .select: return .string(options?.first ?? "")
        default: return .string("")
        }
    }
}

/// Saved setting values per plugin: Data/<id>.settings.json. Changes are pushed to the plugin as `nook.on('settings')`.
enum PluginSettingsStore {
    private static let lock = NSLock()
    private static var stores: [String: SettingsJSONFile<[String: JSONValue]>] = [:]
    private static func url(_ id: String) -> URL {
        Services.supportDir.appendingPathComponent("Data/\(id).settings.json")
    }

    static func saved(_ id: String) -> [String: JSONValue] {
        store(id).read()
    }

    /// Defaults from the manifest, overridden by saved values.
    static func values(for tab: TabItem) -> [String: JSONValue] {
        var out = Dictionary(uniqueKeysWithValues: tab.settings.map { ($0.key, $0.fallback) })
        saved(tab.id).forEach { out[$0.key] = $0.value }
        return out
    }

    static func set(_ tab: TabItem, _ key: String, _ value: JSONValue) {
        let dict = store(tab.id).update { $0[key] = value }
        emit(tab, dict)
    }

    static func reset(_ tab: TabItem) {
        store(tab.id).update { $0 = [:] }
        emit(tab, [:])
    }

    private static func store(_ id: String) -> SettingsJSONFile<[String: JSONValue]> {
        lock.lock()
        defer { lock.unlock() }
        if let store = stores[id] { return store }
        let store = SettingsJSONFile<[String: JSONValue]>(url: { url(id) }, fallback: [:])
        stores[id] = store
        return store
    }

    private static func emit(_ tab: TabItem, _ saved: [String: JSONValue]) {
        let values = Dictionary(uniqueKeysWithValues: tab.settings.map { ($0.key, $0.fallback) }).merging(saved) { _, new in new }
        PluginEvents.emit("settings", values.mapValues(\.any), to: tab.id)
    }
}
