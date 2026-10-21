import Foundation
import ObjectiveC.runtime

/// Open registry. The launcher renders only LauncherAnswer; adding a module never changes its view or other providers.
final class LauncherAnswers: @unchecked Sendable {
    private static var instance: LauncherAnswers?
    static var shared: LauncherAnswers {
        if let instance { return instance }
        let value = LauncherAnswers(); instance = value; return value
    }
    static func disable() { instance = nil }
    static func unregisterIfLoaded(_ id: String) { instance?.unregister(id) }
    static let providerBudget: UInt64 = 2_000_000
    private final class Slot: @unchecked Sendable {
        let provider: LauncherAnswerProvider
        let queue: DispatchQueue
        private let lock = NSLock()
        private var busy = false
        private var retry: (() -> Void)?
        init(_ provider: LauncherAnswerProvider) {
            self.provider = provider; queue = DispatchQueue(label: "nook.answers." + provider.id, qos: .userInitiated)
        }
        func claim(retry: @escaping () -> Void) -> Bool {
            lock.lock(); defer { lock.unlock() }
            if busy { self.retry = retry; return false }; busy = true; return true
        }
        func release() {
            lock.lock(); busy = false; let callback = retry; retry = nil; lock.unlock()
            callback?()
        }
    }
    private final class ResultBox: @unchecked Sendable {
        let lock = NSLock()
        var value: LauncherAnswer?
    }
    private let lock = NSLock()
    private var slots: [Slot] = []

    init(discover: Bool = false) {}
    /// Registration order doesn't affect ranking: stable provider IDs break ties, with the first confident answer winning.
    func register(_ provider: LauncherAnswerProvider) {
        lock.lock(); defer { lock.unlock() }
        slots.removeAll { $0.provider.id == provider.id }
        slots.append(Slot(provider)); slots.sort { $0.provider.id < $1.provider.id }
    }
    func unregister(_ id: String) {
        lock.lock(); defer { lock.unlock() }; slots.removeAll { $0.provider.id == id }
    }
    var providerIDs: [String] { lock.lock(); defer { lock.unlock() }; return slots.map { $0.provider.id } }

    /// Each provider gets at most 2 ms of waiting, on its own serial queue. A timed-out provider stays busy until it
    /// finishes; later keystrokes skip it instead of creating unbounded work. Late results are never published.
    @discardableResult
    func request(_ raw: String, context: LauncherAnswerContext = LauncherAnswerContext(),
                 invalidated: @escaping () -> Void = {}, completion: @escaping (LauncherAnswer?) -> Void) -> LauncherAnswerRequest {
        lock.lock(); let providers = slots; lock.unlock()
        let request = LauncherAnswerRequest()
        let item = DispatchWorkItem {
            let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !request.isCancelled, !query.isEmpty, query.utf8.count <= 512 else {
                if !request.isCancelled { DispatchQueue.main.async { if !request.isCancelled { completion(nil) } } }; return
            }
            var winner: LauncherAnswer?
            for slot in providers {
                guard !request.isCancelled else { return }
                guard slot.claim(retry: { if !request.isCancelled { invalidated() } }) else { continue }
                let box = ResultBox(), signal = DispatchSemaphore(value: 0)
                let snapshot = context
                slot.queue.async {
                    var bounded = snapshot
                    bounded.deadline = DispatchTime.now().uptimeNanoseconds + Self.providerBudget
                    let answer = slot.provider.answer(for: query, context: bounded)
                    if bounded.hasTime { box.lock.lock(); box.value = answer; box.lock.unlock() }
                    slot.release(); signal.signal()
                }
                if signal.wait(timeout: .now() + .nanoseconds(Int(Self.providerBudget))) == .success {
                    box.lock.lock(); winner = box.value; box.lock.unlock()
                }
                if winner != nil {
                    if let refining = slot.provider as? LauncherAnswerRefining {
                        let snapshot = context
                        slot.queue.async { refining.refine(for: query, context: snapshot, completion: { if !request.isCancelled { invalidated() } }) }
                    }
                    break
                }
            }
            guard !request.isCancelled else { return }
            let answer = winner
            DispatchQueue.main.async { if !request.isCancelled { completion(answer) } }
        }
        DispatchQueue.global(qos: .userInitiated).async(execute: item)
        return request
    }
}

/// Separate cancellation state avoids a DispatchWorkItem retaining itself through its closure.
final class LauncherAnswerRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}
