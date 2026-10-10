// Measurement helper for scripts/perf-review. Reads kernel counters and waits for a window.
//
// Usage:
//   probe rusage <pid>...                 one JSON line per pid: cumulative CPU ns, package idle and
//                                         interrupt wakeups, footprint and lifetime peak footprint (bytes)
//   probe window <pid> <timeout-seconds>  waits for the pid's first on-screen window taller than 200 pt;
//                                         prints its frame and ms since the process started
// Build: swiftc -O scripts/perf/probe.swift -o /tmp/cw-perf/bin/probe
import CoreGraphics
import Darwin
import Foundation

var timebase = mach_timebase_info_data_t()
mach_timebase_info(&timebase)
func ns(_ t: UInt64) -> UInt64 { t * UInt64(timebase.numer) / UInt64(timebase.denom) }

func rusage(_ pid: pid_t) -> [String: Any]? {
    var info = rusage_info_v6()
    let rc = withUnsafeMutablePointer(to: &info) { ptr in
        ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
    }
    guard rc == 0 else { return nil }
    return ["pid": pid, "cpu_ns": ns(info.ri_user_time + info.ri_system_time),
            "idle_wakeups": info.ri_pkg_idle_wkups, "interrupt_wakeups": info.ri_interrupt_wkups,
            "footprint": info.ri_phys_footprint, "peak_footprint": info.ri_lifetime_max_phys_footprint,
            "t_ns": ns(mach_absolute_time())]
}

/// Process start time in seconds since 1970, from the kernel.
func startTime(_ pid: pid_t) -> Double? {
    var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    let t = info.kp_proc.p_un.__p_starttime
    return Double(t.tv_sec) + Double(t.tv_usec) / 1e6
}

func mainWindow(_ pid: pid_t) -> (rect: CGRect, id: Int)? {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
    else { return nil }
    for w in list where (w[kCGWindowOwnerPID as String] as? pid_t) == pid && (w[kCGWindowLayer as String] as? Int) == 0 {
        guard let b = w[kCGWindowBounds as String] as? [String: Any], let rect = CGRect(dictionaryRepresentation: b as CFDictionary),
              rect.height > 200 else { continue }
        return (rect, w[kCGWindowNumber as String] as? Int ?? 0)
    }
    return nil
}

func printJSON(_ object: Any) {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}

let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: probe rusage|window ..."); exit(2) }
switch args[1] {
case "rusage":
    for p in args.dropFirst(2).compactMap({ pid_t($0) }) { printJSON(rusage(p) ?? ["pid": p, "gone": true]) }
case "window":
    guard args.count == 4, let pid = pid_t(args[2]), let timeout = Double(args[3]) else { exit(2) }
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let (rect, id) = mainWindow(pid), let start = startTime(pid) {
            printJSON(["ms": Int((Date().timeIntervalSince1970 - start) * 1000),
                       "x": rect.minX, "y": rect.minY, "w": rect.width, "h": rect.height, "id": id])
            exit(0)
        }
        if kill(pid, 0) != 0 { print("{\"error\":\"process gone\"}"); exit(1) }
        usleep(5_000)
    }
    print("{\"error\":\"timeout\"}")
    exit(1)
default:
    print("unknown command"); exit(2)
}
