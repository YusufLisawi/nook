import Foundation

/// Keep typing on the main thread and coalesce disk snapshots on one utility queue.
/// Shutdown drains the queue so the last edit survives an immediate quit.
final class SettingsPersistence {
    static let shared = SettingsPersistence()
    private let queue = DispatchQueue(label: "nook.settings.persistence", qos: .utility)
    private let delay: Double
    private var pending: [String: () -> Void] = [:]
    private var scheduled = false

    init(delay: Double = 0.15) { self.delay = delay }

    func submit(id: String, _ operation: @escaping () -> Void) {
        queue.async {
            self.pending[id] = operation
            guard !self.scheduled else { return }
            self.scheduled = true
            self.queue.asyncAfter(deadline: .now() + self.delay) { self.drain() }
        }
    }

    func flush() { queue.sync { drain() } }

    private func drain() {
        let operations = pending
        pending.removeAll()
        scheduled = false
        for operation in operations.values { operation() }
    }
}

/// A thread-safe, lazy JSON snapshot. Call the first read from a background task.
/// Updates are visible to native services and plugins immediately, before the disk write.
final class SettingsJSONFile<Value: Codable & Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private let url: @Sendable () -> URL
    private let fallback: Value
    private let permissions: Int?
    private var cached: Value?

    init(url: @escaping @Sendable () -> URL, fallback: Value, permissions: Int? = nil) {
        self.url = url
        self.fallback = fallback
        self.permissions = permissions
    }

    func read() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return load()
    }

    @discardableResult
    func update(_ change: (inout Value) -> Void) -> Value {
        lock.lock()
        defer { lock.unlock() }
        var snapshot = load()
        change(&snapshot)
        cached = snapshot
        let saved = snapshot
        let target = url()
        let permissions = permissions
        SettingsPersistence.shared.submit(id: target.path) {
            guard let data = try? JSONEncoder().encode(saved) else { return }
            try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: target, options: .atomic)
            if let permissions { try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path) }
        }
        return snapshot
    }

    /// The caller holds the lock. Missing files are cached too.
    private func load() -> Value {
        if let cached { return cached }
        let value = (try? Data(contentsOf: url())).flatMap { try? JSONDecoder().decode(Value.self, from: $0) } ?? fallback
        cached = value
        return value
    }
}
