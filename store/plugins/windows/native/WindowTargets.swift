import Foundation

/// Each notch owns its pre-open target. No AX or AppKit dependency, so scoping/lifetime can be tested offline.
struct WindowTargets<Window> {
    struct Capture {
        let window: Window?
        let error: String
    }

    private var captures: [String: Capture] = [:]
    private var order: [String] = []

    mutating func capture(_ window: Window?, error: String = "", for context: String) {
        captures[context] = Capture(window: window, error: error)
        order.removeAll { $0 == context }
        order.append(context)
        // Rebuilt/removed notch controllers must not retain AX windows indefinitely.
        while order.count > 16 { captures.removeValue(forKey: order.removeFirst()) }
    }

    func get(_ context: String? = nil) -> Capture? {
        (context ?? order.last).flatMap { captures[$0] }
    }
}
