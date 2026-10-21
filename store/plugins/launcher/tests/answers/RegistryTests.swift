import Foundation

private final class SlowProvider: LauncherAnswerProvider {
    let id = "a-slow"
    func answer(for query: String, context: LauncherAnswerContext) -> LauncherAnswer? {
        Thread.sleep(forTimeInterval: 0.08)
        return LauncherAnswer(expression: query, leftBadge: "Slow", result: "late", rightBadge: "", copyValue: "late")
    }
}
private final class FastProvider: LauncherAnswerProvider {
    let id = "b-fast"
    func answer(for query: String, context: LauncherAnswerContext) -> LauncherAnswer? {
        precondition(!Thread.isMainThread)
        return LauncherAnswer(expression: query, leftBadge: "Fast", result: query, rightBadge: "", copyValue: query)
    }
}
private final class RefiningProvider: LauncherAnswerProvider, LauncherAnswerRefining {
    let id = "refine"
    func answer(for query: String, context: LauncherAnswerContext) -> LauncherAnswer? {
        LauncherAnswer(expression: query, leftBadge: "Cached", result: "cached", rightBadge: "", copyValue: "cached")
    }
    func refine(for query: String, context: LauncherAnswerContext, completion: @escaping () -> Void) {
        precondition(!Thread.isMainThread)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.02, execute: completion)
    }
}

@main struct RegistryTests {
    static func main() {
        func check(_ value: @autoclosure () -> Bool, _ message: String) { precondition(value(), message) }
        func until(_ ready: () -> Bool) {
            let end = Date().addingTimeInterval(1)
            while !ready(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) }
        }
        let registry = LauncherAnswers(discover: false)
        registry.register(SlowProvider()); registry.register(FastProvider())
        var result: LauncherAnswer?
        let start = Date()
        registry.request("fresh") { result = $0 }
        until { result != nil }
        check(result?.copyValue == "fresh", "A slow answer never blocks or beats a fast provider")
        check(Date().timeIntervalSince(start) < 0.04, "Provider deadline bounds waiting independently of an 80 ms provider")
        registry.request("newer") { result = $0 }
        until { result?.copyValue == "newer" }
        check(result?.copyValue == "newer", "Busy providers cannot starve the next query")
        var cancelledDelivered = false
        let cancelled = registry.request("cancelled") { _ in cancelledDelivered = true }
        cancelled.cancel()
        RunLoop.main.run(until: Date().addingTimeInterval(0.12))
        check(!cancelledDelivered, "Cancelled results never publish")
        check(result?.copyValue == "newer", "Late provider results never publish")
        var callbacks = 0
        let refiner = LauncherAnswers(discover: false); refiner.register(RefiningProvider())
        let request = refiner.request("refine", invalidated: { DispatchQueue.main.async { callbacks += 1 } }) { _ in }
        until { callbacks > 0 }
        check(callbacks == 1, "Async refinement invalidates the search without blocking its cached answer")
        request.cancel()
        var oversized: LauncherAnswer?; var oversizedDone = false
        registry.request(String(repeating: "1", count: 513)) { oversized = $0; oversizedDone = true }
        until { oversizedDone }
        check(oversizedDone && oversized == nil, "Oversized expressions don't enter providers")
        print("Passed registry deadline, cancellation, background execution, refinement and input-bound checks")
    }
}
