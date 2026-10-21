import Foundation

extension MouseFixService {
    func registerBridge() {
        BridgeRegistry.register("mouse", functions: ["state", "set", "setButton", "removeButton", "learn", "openPrivacy"]) { [weak self] fn, args, _, reply in
            guard let self else { reply(nil, "Mouse service unavailable"); return }
            self.handle(fn, args: args, reply: reply)
        }
    }
}
