import Foundation

/// A page owns its bridge work. Cancellation also covers requests queued before the page disappeared.
final class PluginWork: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var operations: [UUID: () -> Void] = [:]
    @discardableResult func add(_ id: UUID, cancel: @escaping () -> Void) -> Bool {
        lock.lock()
        if cancelled { lock.unlock(); cancel(); return false }
        operations[id] = cancel; lock.unlock(); return true
    }
    func remove(_ id: UUID) { lock.lock(); operations.removeValue(forKey: id); lock.unlock() }
    func perform(_ operation: () throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        try operation()
    }
    func cancel() {
        lock.lock(); cancelled = true; let pending = operations.values; operations = [:]; lock.unlock()
        for operation in pending { operation() }
    }
}
