import Darwin
import Foundation

/// Development: with CANDY_LAUNCH_TIMING set, prints each launch milestone once to stderr as
/// seconds since the process started (docs/benchmarks.md). Callable from any thread.
public enum LaunchTiming {
    private static let enabled = ProcessInfo.processInfo.environment["CANDY_LAUNCH_TIMING"] != nil
    private static let seen = LabelSet()

    public static func mark(_ label: String) {
        guard enabled, seen.insert(label) else { return }
        var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return }
        let start = info.kp_proc.p_un.__p_starttime
        let elapsed = Date().timeIntervalSince1970 - (Double(start.tv_sec) + Double(start.tv_usec) / 1e6)
        FileHandle.standardError.write(Data(String(format: "launch-timing %@ %.3f s\n", label, elapsed).utf8))
    }
}

private final class LabelSet: @unchecked Sendable {
    private let lock = NSLock()
    private var labels = Set<String>()
    func insert(_ label: String) -> Bool { lock.withLock { labels.insert(label).inserted } }
}
