import Foundation

/// Serializes Cleaner requests from multiple notches; never reads or creates ~/.Trash.
enum CleanerBridge {
    private static let queue = DispatchQueue(label: "com.yusuf.nook.cleaner", qos: .userInitiated)

    static func register() {
        BridgeRegistry.register("cleaner", functions: ["clean"]) { fn, args, _, reply in
            guard fn == "clean" else { reply(nil, "Unknown Cleaner action."); return }
            guard let category = args.first as? String, CleanerEngine.roots[category] != nil else {
                reply(nil, "Unknown cleanup category."); return
            }
            let days = args.count > 1 ? args[1] as? Int ?? 60 : 60
            queue.async {
                do {
                    let result = try CleanerEngine().clean(category: category, days: days)
                    DispatchQueue.main.async { reply(result.payload, nil) }
                } catch {
                    DispatchQueue.main.async { reply(nil, error.localizedDescription) }
                }
            }
        }
    }
}
