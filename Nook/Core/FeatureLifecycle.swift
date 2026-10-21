import Foundation

/// Pure lifecycle engine. Descriptors contain factories, never service instances.
struct Feature {
    let id: String
    let title: String
    let summary: String
    let memoryNote: String
    var defaultEnabled = true
    var tabs: [String] = []
    var dependencies: [String] = []
    var start: () -> Void = {}
    var stop: () -> Void = {}
}

final class FeatureLifecycle {
    static let migrationKey = "features.raycastMigration.v1"
    static let raycastIDs: Set<String> = ["launcher", "smartAnswers", "launcherFiles", "files", "clipboard", "screenshots", "windows", "mouse"]
    private(set) var features: [Feature] = []
    private(set) var running = Set<String>()
    let defaults: UserDefaults
    private var reconciling = false
    private var stopped = false

    init(defaults: UserDefaults) { self.defaults = defaults }
    func register(_ feature: Feature) {
        guard !features.contains(where: { $0.id == feature.id }) else { return }
        features.append(feature)
    }
    static func key(_ id: String) -> String { "features.enabled." + id }
    var disabledTabs: Set<String> {
        Set((defaults.string(forKey: "disabledTabs") ?? "").split(separator: ",").map(String.init))
    }
    func requested(_ id: String) -> Bool {
        guard let feature = features.first(where: { $0.id == id }) else { return true }
        let choice = defaults.object(forKey: Self.key(id)) as? Bool ?? feature.defaultEnabled
        return choice && (feature.tabs.isEmpty || feature.tabs.contains { !disabledTabs.contains($0) })
    }
    func enabled(_ id: String) -> Bool { enabled(id, visiting: []) }
    private func enabled(_ id: String, visiting: Set<String>) -> Bool {
        guard !visiting.contains(id), requested(id) else { return false }
        guard let feature = features.first(where: { $0.id == id }) else { return true }
        return feature.dependencies.allSatisfy { enabled($0, visiting: visiting.union([id])) }
    }
    /// Applies once on the next launch, before any feature factory can run. Never touches shortcuts or history.
    func migrate() {
        guard !defaults.bool(forKey: Self.migrationKey) else { return }
        var off = disabledTabs
        for feature in features where Self.raycastIDs.contains(feature.id) {
            defaults.set(false, forKey: Self.key(feature.id)); off.formUnion(feature.tabs)
        }
        defaults.set(off.sorted().joined(separator: ","), forKey: "disabledTabs")
        defaults.set(true, forKey: Self.migrationKey)
    }
    func set(_ id: String, enabled: Bool) {
        guard let feature = features.first(where: { $0.id == id }) else { return }
        defaults.set(enabled, forKey: Self.key(id))
        var off = disabledTabs
        for tab in feature.tabs {
            if enabled { off.remove(tab) }
            // Shared tabs (Clips) stay available while either owner is on.
            else if !features.contains(where: { $0.id != id && $0.tabs.contains(tab) && requested($0.id) }) { off.insert(tab) }
        }
        defaults.set(off.sorted().joined(separator: ","), forKey: "disabledTabs")
        reconcile()
    }
    /// The existing Tabs switches also control the native owner, including shared tabs.
    func setTab(_ tab: String, enabled: Bool) {
        let owners = features.filter { $0.tabs.contains(tab) }
        for owner in owners { defaults.set(enabled, forKey: Self.key(owner.id)) }
        var off = disabledTabs
        if enabled { off.remove(tab) } else { off.insert(tab) }
        defaults.set(off.sorted().joined(separator: ","), forKey: "disabledTabs")
        reconcile()
    }
    func reconcile() {
        guard !reconciling, !stopped else { return }
        reconciling = true
        defer { reconciling = false }
        // Stop dependents first, start dependencies first (catalog is dependency-ordered).
        for feature in features.reversed() where running.contains(feature.id) && !enabled(feature.id) {
            running.remove(feature.id); feature.stop()
        }
        for feature in features where !running.contains(feature.id) && enabled(feature.id) {
            running.insert(feature.id); feature.start()
        }
    }
    func shutdown() {
        stopped = true
        for feature in features.reversed() where running.remove(feature.id) != nil { feature.stop() }
    }
}
