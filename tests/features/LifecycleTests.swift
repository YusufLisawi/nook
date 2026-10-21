import Foundation

@main struct LifecycleTests {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ label: String) {
        checks += 1
        guard value() else { fatalError(label) }
    }
    static func main() {
        let suite = "nook.features.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let engine = FeatureLifecycle(defaults: defaults)
        final class FakeService {
            var hotkeys = 0, observers = 0, starts = 0, stops = 0
            func start() { starts += 1; hotkeys += 1; observers += 1 }
            func stop() { stops += 1; hotkeys -= 1; observers -= 1 }
        }
        let fake = FakeService()
        engine.register(Feature(id: "files", title: "Files", summary: "", memoryNote: "", defaultEnabled: false, tabs: ["files"], start: fake.start, stop: fake.stop))
        engine.reconcile(); engine.reconcile()
        check(fake.starts == 0 && fake.hotkeys == 0 && fake.observers == 0, "disabled factories must never register resources")
        engine.set("files", enabled: true); engine.reconcile()
        check(fake.starts == 1 && fake.hotkeys == 1 && fake.observers == 1, "start exactly once")
        engine.set("files", enabled: false); engine.reconcile()
        check(fake.stops == 1 && fake.hotkeys == 0 && fake.observers == 0, "stop removes all resources once")
        engine.set("files", enabled: true)
        check(fake.starts == 2, "restart works")
        defaults.set("files", forKey: "disabledTabs"); engine.reconcile()
        check(fake.stops == 2 && !engine.enabled("files"), "legacy plugin switch tears down native owner")
        engine.setTab("files", enabled: true)
        check(fake.starts == 3 && engine.enabled("files"), "existing plugin switch restores owner")
        let keyboardChoice = Data([1, 2, 3])
        defaults.set(keyboardChoice, forKey: "tabHotkeys")
        engine.register(Feature(id: "launcher", title: "Launcher", summary: "", memoryNote: "", defaultEnabled: false))
        engine.register(Feature(id: "smartAnswers", title: "Answers", summary: "", memoryNote: "", defaultEnabled: false, dependencies: ["launcher"]))
        engine.register(Feature(id: "notes", title: "Notes", summary: "", memoryNote: "", tabs: ["notes"]))
        engine.register(Feature(id: "clipboard", title: "Clipboard", summary: "", memoryNote: "", defaultEnabled: false, tabs: ["clips"]))
        engine.register(Feature(id: "screenshots", title: "Screenshots", summary: "", memoryNote: "", defaultEnabled: false, tabs: ["clips"]))
        engine.set("smartAnswers", enabled: true)
        check(!engine.enabled("smartAnswers"), "dependencies block work while preserving choice")
        engine.set("launcher", enabled: true)
        check(engine.enabled("smartAnswers"), "dependency enable starts dependent lazily")
        engine.set("clipboard", enabled: true); engine.set("screenshots", enabled: true)
        engine.set("clipboard", enabled: false)
        check(engine.enabled("screenshots") && !engine.disabledTabs.contains("clips"), "shared tab remains for other enabled owner")
        engine.set("screenshots", enabled: false)
        check(engine.disabledTabs.contains("clips"), "shared tab hides after last owner disabled")
        engine.set("screenshots", enabled: true)
        check(engine.enabled("screenshots") && !engine.enabled("clipboard"), "shared tab enable doesn't revive other service")
        engine.migrate(); engine.reconcile()
        for id in ["files", "launcher", "smartAnswers", "clipboard", "screenshots"] { check(!engine.enabled(id), "migration disables \(id)") }
        check(engine.enabled("notes"), "migration keeps enabled products")
        check(defaults.data(forKey: "tabHotkeys") == keyboardChoice, "migration preserves shortcut bytes")
        engine.set("launcher", enabled: true); engine.migrate()
        check(engine.enabled("launcher"), "migration only once; explicit later choice wins")
        let count = engine.features.count
        engine.register(Feature(id: "launcher", title: "Duplicate", summary: "", memoryNote: ""))
        check(engine.features.count == count, "duplicate registration is inert")
        engine.set("files", enabled: true)
        engine.shutdown(); engine.shutdown(); engine.reconcile()
        check(fake.hotkeys == 0 && fake.observers == 0 && engine.running.isEmpty, "shutdown is final and idempotent")
        var owned: FakeService?
        weak var weakService: FakeService?
        let memory = FeatureLifecycle(defaults: defaults)
        memory.register(Feature(id: "memory", title: "", summary: "", memoryNote: "", defaultEnabled: false,
            start: { owned = FakeService(); weakService = owned; owned?.start() },
            stop: { owned?.stop(); owned = nil }))
        memory.reconcile()
        check(weakService == nil, "disabled service was never allocated")
        memory.set("memory", enabled: true)
        check(weakService != nil, "explicit enable allocates service")
        memory.set("memory", enabled: false)
        check(weakService == nil, "stop releases last owner and cached resource instance")
        let cycle = FeatureLifecycle(defaults: defaults)
        cycle.register(Feature(id: "cycle", title: "", summary: "", memoryNote: "", dependencies: ["cycle"]))
        check(!cycle.enabled("cycle"), "cycles fail closed")
        print("Features: \(checks) lifecycle/default/migration/resource checks passed")
    }
}
