import Foundation

/// At most one request and one latest replacement per provider/display. Typing cannot flood a helper.
final class PluginSearchQueue {
    typealias Work = (@escaping () -> Void) -> Void
    private var active: [String: UUID] = [:]
    private var waiting: [String: Work] = [:]
    func submit(_ key: String, work: @escaping Work) {
        if active[key] != nil { waiting[key] = work; return }
        let token = UUID(); active[key] = token
        work { [weak self] in
            guard let self, self.active[key] == token else { return }
            self.active.removeValue(forKey: key)
            if let next = self.waiting.removeValue(forKey: key) { self.submit(key, work: next) }
        }
    }
    func cancel(prefix: String) {
        waiting = waiting.filter { !$0.key.hasPrefix(prefix) }
        active = active.filter { !$0.key.hasPrefix(prefix) }
    }
}
