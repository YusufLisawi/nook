import Foundation
import IOKit.ps

/// CPU, memory, disk, network, battery — sampled on demand; rates use the previous sample.
final class SystemStats {
    private var lastCPU: host_cpu_load_info?
    private var lastNet: (rx: UInt64, tx: UInt64, at: Date)?

    func snapshot() -> [String: Any] {
        var load = [Double](repeating: 0, count: 3)
        getloadavg(&load, 3)
        let thermal: String = switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "nominal"
        }
        return [
            "cpu": ["usage": cpuUsage(), "cores": ProcessInfo.processInfo.activeProcessorCount],
            "memory": memory(),
            "disk": disk(),
            "network": network(),
            "battery": battery() ?? NSNull(),
            "load": load,
            "uptime": ProcessInfo.processInfo.systemUptime,
            "thermal": thermal,
        ]
    }

    private func cpuUsage() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return 0 }
        defer { lastCPU = info }
        guard let prev = lastCPU else { return 0 }
        let user = Double(info.cpu_ticks.0 &- prev.cpu_ticks.0)
        let system = Double(info.cpu_ticks.1 &- prev.cpu_ticks.1)
        let idle = Double(info.cpu_ticks.2 &- prev.cpu_ticks.2)
        let nice = Double(info.cpu_ticks.3 &- prev.cpu_ticks.3)
        let total = user + system + idle + nice
        return total > 0 ? (user + system + nice) / total : 0
    }

    private func memory() -> [String: Any] {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        let total = ProcessInfo.processInfo.physicalMemory
        guard result == KERN_SUCCESS else { return ["used": 0, "total": total] }
        let page = UInt64(vm_kernel_page_size)
        // Matches Activity Monitor's "Memory Used": app memory + wired + compressed.
        let app = UInt64(stats.internal_page_count) - UInt64(stats.purgeable_count)
        let used = (app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
        return ["used": used, "total": total]
    }

    private func disk() -> [String: Any] {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys)
        let total = Int64(values?.volumeTotalCapacity ?? 0)
        let free = values?.volumeAvailableCapacityForImportantUsage ?? 0
        return ["used": max(0, total - free), "total": total, "free": free]
    }

    private func network() -> [String: Any] {
        var rx: UInt64 = 0, tx: UInt64 = 0
        var addrs: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&addrs) == 0 {
            var cursor = addrs
            while let ifa = cursor?.pointee {
                // Physical interfaces only (en*); tunnels would double-count VPN traffic.
                if ifa.ifa_addr?.pointee.sa_family == UInt8(AF_LINK), String(cString: ifa.ifa_name).hasPrefix("en"),
                   let data = ifa.ifa_data?.assumingMemoryBound(to: if_data.self).pointee {
                    rx += UInt64(data.ifi_ibytes)
                    tx += UInt64(data.ifi_obytes)
                }
                cursor = ifa.ifa_next
            }
            freeifaddrs(addrs)
        }
        let now = Date()
        defer { lastNet = (rx, tx, now) }
        guard let prev = lastNet else { return ["downBps": 0, "upBps": 0] }
        let dt = max(0.001, now.timeIntervalSince(prev.at))
        return ["downBps": Double(rx &- prev.rx) / dt, "upBps": Double(tx &- prev.tx) / dt]
    }

    private func battery() -> [String: Any]? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef],
              let source = list.first,
              let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
              let current = desc[kIOPSCurrentCapacityKey] as? Int,
              let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0
        else { return nil }
        let minutes = desc[kIOPSTimeToEmptyKey] as? Int ?? -1
        return [
            "percent": Double(current) / Double(max) * 100,
            "charging": desc[kIOPSIsChargingKey] as? Bool ?? false,
            "onAC": (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue,
            "minutesLeft": minutes > 0 ? minutes : NSNull(),
        ]
    }
}
