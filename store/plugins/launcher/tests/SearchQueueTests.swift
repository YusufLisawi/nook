import Foundation
@main enum SearchQueueTests {
    static func main() {
        let queue = PluginSearchQueue()
        var runs: [Int] = [], finishes: [() -> Void] = []
        for index in 0..<1000 { queue.submit("apps/display-a") { done in runs.append(index); finishes.append(done) } }
        precondition(runs == [0], "Typing must not create parallel helper requests")
        queue.submit("apps/display-b") { done in runs.append(-1); done() }
        precondition(runs == [0, -1], "Displays must not block each other")
        finishes.removeFirst()()
        precondition(runs == [0, -1, 999], "Only the latest pending query runs")
        queue.submit("apps/display-a") { _ in fatalError("Disabled provider must not run its queued query") }
        queue.cancel(prefix: "apps/")
        finishes.removeFirst()()
        queue.submit("apps/display-a") { done in runs.append(1001); done() }
        precondition(runs.last == 1001, "Re-enable starts cleanly")
        print("PASS: 1,000 keystrokes coalesce, independent displays, disable cleanup and re-enable")
    }
}
