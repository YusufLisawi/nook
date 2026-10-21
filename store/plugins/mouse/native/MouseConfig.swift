import Foundation

/// Mouse tab settings: saved as JSON in UserDefaults, edited by the Mouse plugin through `nook.mouse.*`.
struct MouseConfig: Codable, Equatable {
    static let smoothnessLevels = ["off", "low", "regular", "high"]
    static let modifiers = ["none", "shift", "option", "control", "command"]

    var enabled = false
    var smoothness = "regular"
    var speed = 1.0 // 0.3 … 3, × the base distance of one wheel tick
    var acceleration = 0.5 // 0 … 1, how much a fast spin speeds scrolling up
    var reverse = false
    var filterChatter = false // opt in only for wheels that bounce on direction changes
    var horizontalModifier = "shift" // hold to scroll sideways
    var preciseModifier = "none" // hold to scroll slowly
    var quickModifier = "none" // hold to scroll fast
    var buttons: [String: ButtonRule] = [:] // mouse button number → rule (2 = middle, 3 = back, 4 = forward…)

    struct ButtonRule: Codable, Equatable {
        var click = "none"
        var hold = "none" // press and hold
        var drag = "none" // "none" | "spaces" (left/right = Spaces, up = Mission Control, down = App Exposé)

        var isActive: Bool { click != "none" || hold != "none" || drag != "none" }

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            click = try c.decodeIfPresent(String.self, forKey: .click) ?? "none"
            hold = try c.decodeIfPresent(String.self, forKey: .hold) ?? "none"
            drag = try c.decodeIfPresent(String.self, forKey: .drag) ?? "none"
        }
    }

    init() {}

    /// Missing keys fall back to defaults, so adding a setting later never wipes what people saved.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MouseConfig()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        smoothness = try c.decodeIfPresent(String.self, forKey: .smoothness) ?? d.smoothness
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? d.speed
        acceleration = try c.decodeIfPresent(Double.self, forKey: .acceleration) ?? d.acceleration
        reverse = try c.decodeIfPresent(Bool.self, forKey: .reverse) ?? d.reverse
        filterChatter = try c.decodeIfPresent(Bool.self, forKey: .filterChatter) ?? d.filterChatter
        horizontalModifier = try c.decodeIfPresent(String.self, forKey: .horizontalModifier) ?? d.horizontalModifier
        preciseModifier = try c.decodeIfPresent(String.self, forKey: .preciseModifier) ?? d.preciseModifier
        quickModifier = try c.decodeIfPresent(String.self, forKey: .quickModifier) ?? d.quickModifier
        buttons = try c.decodeIfPresent([String: ButtonRule].self, forKey: .buttons) ?? d.buttons
        normalize()
    }

    /// Clamp numbers and drop unknown choices, so a bad value from a plugin can't break scrolling.
    mutating func normalize() {
        if !Self.smoothnessLevels.contains(smoothness) { smoothness = "regular" }
        speed = min(3, max(0.3, speed))
        acceleration = min(1, max(0, acceleration))
        if !Self.modifiers.contains(horizontalModifier) { horizontalModifier = "none" }
        if !Self.modifiers.contains(preciseModifier) { preciseModifier = "none" }
        if !Self.modifiers.contains(quickModifier) { quickModifier = "none" }
        let known = Set(MouseActions.all.map(\.id))
        buttons = buttons.filter { Int($0.key).map { $0 >= 2 } ?? false } // left (0) and right (1) are never remapped
            .mapValues { rule in
                var r = rule
                if !known.contains(r.click) { r.click = "none" }
                if !known.contains(r.hold) { r.hold = "none" }
                if r.drag != "spaces" { r.drag = "none" }
                return r
            }
    }

    // MARK: Persistence

    private static var file: URL? {
        ProcessInfo.processInfo.environment["NOOK_DATA_DIR"].map { URL(fileURLWithPath: $0).appendingPathComponent("mouse.json") }
    }

    static func load() -> MouseConfig {
        if let file, let data = try? Data(contentsOf: file), let config = try? JSONDecoder().decode(MouseConfig.self, from: data) { return config }
        // Read-only migration. Never write Nook's old preferences from the helper.
        return UserDefaults(suiteName: "com.yusuf.nook")?.data(forKey: "mouseFixConfig")
            .flatMap { try? JSONDecoder().decode(MouseConfig.self, from: $0) } ?? MouseConfig()
    }

    func save() {
        guard let file = Self.file else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(self).write(to: file, options: .atomic)
        } catch { FileHandle.standardError.write(Data("Couldn’t save mouse settings: \(error.localizedDescription)\n".utf8)) }
    }

    // MARK: Bridge

    var json: [String: Any] {
        (try? JSONEncoder().encode(self)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }

    /// Overlay the keys a plugin sent on top of the current values; nil if a value has the wrong type.
    func merging(_ patch: [String: Any]) -> MouseConfig? {
        var merged = json
        for (k, v) in patch where k != "buttons" && merged[k] != nil { merged[k] = v }
        guard let data = try? JSONSerialization.data(withJSONObject: merged),
              var result = try? JSONDecoder().decode(MouseConfig.self, from: data) else { return nil }
        result.normalize()
        return result
    }
}
