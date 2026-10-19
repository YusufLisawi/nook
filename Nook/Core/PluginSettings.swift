import AppKit
import SwiftUI

/// A JSON scalar (manifest defaults + saved values).
enum JSONValue: Codable, Equatable {
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
    private static func url(_ id: String) -> URL {
        Services.supportDir.appendingPathComponent("Data/\(id).settings.json")
    }

    static func saved(_ id: String) -> [String: JSONValue] {
        guard let data = try? Data(contentsOf: url(id)) else { return [:] }
        return (try? JSONDecoder().decode([String: JSONValue].self, from: data)) ?? [:]
    }

    /// Defaults from the manifest, overridden by saved values.
    static func values(for tab: TabItem) -> [String: JSONValue] {
        var out = Dictionary(uniqueKeysWithValues: tab.settings.map { ($0.key, $0.fallback) })
        saved(tab.id).forEach { out[$0.key] = $0.value }
        return out
    }

    static func set(_ tab: TabItem, _ key: String, _ value: JSONValue) {
        var dict = saved(tab.id)
        dict[key] = value
        write(tab, dict)
    }

    static func reset(_ tab: TabItem) { write(tab, [:]) }

    private static func write(_ tab: TabItem, _ dict: [String: JSONValue]) {
        try? FileManager.default.createDirectory(at: url(tab.id).deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(dict) { try? data.write(to: url(tab.id), options: .atomic) }
        PluginEvents.emit("settings", values(for: tab).mapValues(\.any), to: tab.id)
    }
}

/// Auto-generated settings form for a plugin, plus code-level customisation (Edit code / Revert).
struct PluginSettingsForm: View {
    let tab: TabItem
    var compact = false
    var onDone: (() -> Void)?
    @State private var values: [String: JSONValue]
    @ObservedObject private var plugins = Services.shared.plugins

    init(tab: TabItem, compact: Bool = false, onDone: (() -> Void)? = nil) {
        self.tab = tab
        self.compact = compact
        self.onDone = onDone
        _values = State(initialValue: PluginSettingsStore.values(for: tab))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 12) {
            heightControl
            if tab.settings.isEmpty, tab.isWeb {
                Text("No other options yet. Edit its code to change anything else.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ForEach(tab.settings) { setting in
                VStack(alignment: .leading, spacing: 3) {
                    if [.text, .secret, .textarea, .number].contains(setting.type), !(setting.type == .number && setting.min != nil && setting.max != nil) {
                        Text(setting.label).font(.system(size: compact ? 11 : 12, weight: .medium)).foregroundStyle(.secondary)
                    }
                    control(for: setting)
                    if let help = setting.help {
                        Text(help).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }
            HStack(spacing: 8) {
                if tab.isWeb {
                    Button(plugins.isBundled(tab) ? "Edit code…" : "Show code") { plugins.customize(tab) }
                        .help(plugins.isBundled(tab) ? "Copy this plugin to your Plugins folder and open it — your copy replaces the built-in one" : "Open the plugin folder")
                    if plugins.overridesBundled(tab) {
                        Button("Revert to built-in") { plugins.revert(tab) }
                    }
                }
                Spacer()
                if !tab.settings.isEmpty {
                    Button("Reset") {
                        PluginSettingsStore.reset(tab)
                        values = PluginSettingsStore.values(for: tab)
                    }
                }
                if let onDone { Button("Done", action: onDone).keyboardShortcut(.defaultAction) }
            }
            .controlSize(compact ? .small : .regular)
        }
        .font(.system(size: compact ? 12 : 13))
        .tint(.orange) // Nook accent, not the system colour
    }

    /// Every tab: how tall the notch opens for it. Live while dragging.
    private var heightControl: some View {
        let height = Binding<Double>(
            get: { Double(plugins.height(for: tab)) },
            set: { plugins.setHeight(tab.id, CGFloat($0)) }
        )
        return LabeledContent("Height") {
            HStack(spacing: 8) {
                Slider(value: height, in: Double(PluginRegistry.minHeight)...Double(PluginRegistry.maxHeight), step: 10)
                Text("\(Int(height.wrappedValue))").monospacedDigit().frame(width: 30, alignment: .trailing)
                if plugins.userHeights[tab.id] != nil {
                    Button("Default") { plugins.setHeight(tab.id, nil) }.buttonStyle(.link).font(.caption)
                }
            }
        }
    }

    private func binding(_ setting: PluginSetting) -> Binding<JSONValue> {
        Binding(
            get: { values[setting.key] ?? setting.fallback },
            set: { value in
                values[setting.key] = value
                PluginSettingsStore.set(tab, setting.key, value)
            }
        )
    }

    @ViewBuilder
    private func control(for s: PluginSetting) -> some View {
        let value = binding(s)
        switch s.type {
        case .toggle:
            Toggle(s.label, isOn: Binding(get: { value.wrappedValue.bool }, set: { value.wrappedValue = .bool($0) }))
        case .select:
            Picker(s.label, selection: Binding(get: { value.wrappedValue.string }, set: { value.wrappedValue = .string($0) })) {
                ForEach(s.options ?? [], id: \.self) { Text($0).tag($0) }
            }
        case .number where s.min != nil && s.max != nil:
            LabeledContent(s.label) {
                HStack {
                    Slider(value: Binding(get: { value.wrappedValue.number }, set: { value.wrappedValue = .number($0) }),
                           in: s.min!...s.max!, step: s.step ?? 1)
                    Text(value.wrappedValue.string).monospacedDigit().frame(width: 38, alignment: .trailing)
                }
            }
        case .number:
            TextField("", value: Binding(get: { value.wrappedValue.number }, set: { value.wrappedValue = .number($0) }), format: .number)
                .labelsHidden()
        case .color:
            ColorPicker(s.label, selection: Binding(
                get: { Color(css: value.wrappedValue.string) },
                set: { value.wrappedValue = .string(NSColor($0).usingColorSpace(.sRGB).map { String(format: "#%02x%02x%02x", Int($0.redComponent * 255), Int($0.greenComponent * 255), Int($0.blueComponent * 255)) } ?? "#ffffff") }
            ), supportsOpacity: false)
        case .secret:
            SecureField("", text: Binding(get: { value.wrappedValue.string }, set: { value.wrappedValue = .string($0) }))
        case .textarea:
            TextField("", text: Binding(get: { value.wrappedValue.string }, set: { value.wrappedValue = .string($0) }), axis: .vertical)
                .lineLimit(2...5)
        case .text:
            TextField("", text: Binding(get: { value.wrappedValue.string }, set: { value.wrappedValue = .string($0) }))
        }
    }
}
