import Darwin
import Foundation

enum ProcessTree {
    static func terminateTree(_ pid: pid_t) {
        guard pid > 0 else { return }
        kill(pid, SIGSTOP)
        kill(-pid, SIGSTOP)
        let descendants = Self.descendants(of: pid)
        // Stop leaves first, then the CLI, so grandchildren cannot escape by being reparented.
        for child in descendants.reversed() { kill(child, SIGKILL) }
        kill(-pid, SIGKILL)
        kill(pid, SIGKILL)
    }

    private static func descendants(of parent: pid_t) -> [pid_t] {
        // Unlike proc_listpids, proc_listchildpids returns a PID count, not a byte count.
        let capacity = proc_listchildpids(parent, nil, 0)
        guard capacity > 0 else { return [] }
        var children = [pid_t](repeating: 0, count: Int(capacity) + 32)
        let count = children.withUnsafeMutableBytes { proc_listchildpids(parent, $0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return [] }
        let direct = children.prefix(Int(count)).filter { $0 > 0 }
        return direct.flatMap { child -> [pid_t] in
            kill(child, SIGSTOP)
            return [child] + descendants(of: child)
        }
    }
}
