import Foundation

/// Serializes Cleaner requests from multiple notches; never reads or creates ~/.Trash.
enum CleanerBridge {
    private static let queue = DispatchQueue(label: "com.yusuf.nook.cleaner", qos: .userInitiated)

    private static let lock = NSLock()
    private static var generation = 0
    private static var current: Process?
    static func stop() {
        lock.lock(); generation += 1; let process = current; current = nil; lock.unlock()
        if process?.isRunning == true { process?.terminate() }
        BridgeRegistry.unregister("cleaner")
    }

    static func register() {
        BridgeRegistry.register("cleaner", functions: ["clean"]) { fn, args, _, reply in
            guard fn == "clean" else { reply(nil, "Unknown Cleaner action."); return }
            guard let category = args.first as? String, CleanerEngine.roots[category] != nil else {
                reply(nil, "Unknown cleanup category."); return
            }
            let days = args.count > 1 ? args[1] as? Int ?? 60 : 60
            lock.lock(); let token = generation; lock.unlock()
            queue.async {
                let cancelled = { () -> Bool in lock.lock(); defer { lock.unlock() }; return token != generation }
                defer { lock.lock(); current = nil; lock.unlock() }
                do {
                    let engine = CleanerEngine(isCancelled: cancelled, launch: { process in
                        lock.lock(); defer { lock.unlock() }
                        guard token == generation else { throw CancellationError() }
                        try process.run(); current = process
                    })
                    let result = try engine.clean(category: category, days: days)
                    DispatchQueue.main.async { reply(result.payload, nil) }
                } catch {
                    DispatchQueue.main.async { reply(nil, error.localizedDescription) }
                }
            }
        }
    }
}
