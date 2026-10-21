import Foundation

/// Cross-queue visibility hint. Background services use it to avoid producing UI payloads for absent pages.
enum FeatureVisibility {
    private static let lock = NSLock()
    private static var owners: [String: String] = [:]
    static func set(owner: String, plugin: String?) {
        lock.lock(); defer { lock.unlock() }; owners[owner] = plugin
    }
    static func isVisible(_ plugin: String) -> Bool {
        lock.lock(); defer { lock.unlock() }; return owners.values.contains(plugin)
    }
}
