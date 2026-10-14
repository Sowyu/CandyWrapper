import AppKit
import Darwin

/// Development and perf runs: with CANDY_STALLS set, logs to stderr `stall-monitor on`, then
///
/// - `stall <ms> ms` for every main run loop pass, wake to sleep, of 50 ms or more, followed by
///   `  sample <ms into the pass>` stacks of the main thread taken by a watchdog thread 50 ms into
///   the pass and every 100 ms after,
/// - `frame-gap <ms> ms <frames> dropped <reason>` when the display link misses two or more
///   refreshes while the user scrolls, types, drags or resizes (or `--perf-scroll` runs),
/// - `key-latency <ms> ms` from a key event's timestamp to the end of the pass that handled it,
///   after Core Animation committed its frame.
///
/// Off, nothing is installed. On and idle, the watchdog waits on a semaphore and the display link
/// is stopped, so it adds no wakeups. Frames print as image+offset and dladdr's symbol, so `atos`
/// can resolve a stripped build.
@MainActor
enum StallMonitor {
    static let enabled = ProcessInfo.processInfo.environment["CANDY_STALLS"] != nil
    nonisolated static let threshold: Double = 0.050

    private static let shared = Shared()
    private static var observer: CFRunLoopObserver?
    private static var link: CADisplayLink?
    private static var lastFrame: CFTimeInterval = 0
    private static var armedUntil: TimeInterval = 0
    private static var armReason = ""
    private static var pendingKey: TimeInterval?

    static func start() {
        guard enabled, observer == nil else { return }
        FileHandle.standardError.write(Data("stall-monitor on\n".utf8))
        shared.mainThread = pthread_mach_thread_np(pthread_self())
        // Order Int.max: after Core Animation's commit (2,000,000), so the commit counts.
        let o = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue,
                                                   true, CFIndex.max) { _, activity in
            MainActor.assumeIsolated { runLoop(activity) }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), o, .commonModes)
        observer = o
        let t = Thread { shared.watch() }
        t.name = "stall-watchdog"
        t.qualityOfService = .userInteractive
        t.start()
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel, .leftMouseDragged]) { event in
            MainActor.assumeIsolated {
                switch event.type {
                case .keyDown: pendingKey = event.timestamp; arm("typing")
                case .scrollWheel: arm("scroll")
                default: arm("drag")
                }
            }
            return event
        }
        for name in [NSWindow.willStartLiveResizeNotification, NSWindow.didResizeNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { arm("resize") }
            }
        }
    }

    /// Watches frame gaps for the next half second.
    static func arm(_ reason: String) {
        guard enabled else { return }
        armedUntil = ProcessInfo.processInfo.systemUptime + 0.5
        armReason = reason
        guard link == nil, let view = NSApp.keyWindow?.contentView ?? NSApp.windows.first(where: \.isVisible)?.contentView else { return }
        let l = view.displayLink(target: LinkTarget.shared, selector: #selector(LinkTarget.tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
        lastFrame = 0
    }

    fileprivate static func tick(_ l: CADisplayLink) {
        let refresh = max(l.duration, 1.0 / 240)
        if lastFrame > 0 {
            let gap = l.timestamp - lastFrame
            if gap > refresh * 2.5 {
                shared.log(String(format: "frame-gap %.1f ms %d dropped %@", gap * 1000, Int((gap / refresh).rounded()) - 1, armReason))
            }
        }
        lastFrame = l.timestamp
        if ProcessInfo.processInfo.systemUptime > armedUntil {
            l.invalidate()
            link = nil
        }
    }

    private static func runLoop(_ activity: CFRunLoopActivity) {
        let now = ProcessInfo.processInfo.systemUptime
        if activity == .afterWaiting {
            shared.passBegan(now)
        } else {
            shared.passEnded(now)
            if let key = pendingKey {
                pendingKey = nil
                shared.log(String(format: "key-latency %.1f ms", (now - key) * 1000))
            }
        }
    }

    @MainActor private final class LinkTarget: NSObject {
        static let shared = LinkTarget()
        @objc func tick(_ l: CADisplayLink) { StallMonitor.tick(l) }
    }
}

/// State shared between the main thread's observer and the watchdog, behind one lock.
private final class Shared: @unchecked Sendable {
    var mainThread: mach_port_t = 0
    private var lock = os_unfair_lock()
    private let wake = DispatchSemaphore(value: 0)
    private var pass: UInt64 = 0
    private var passStart: TimeInterval = 0
    private var running = false
    private var idle = false
    private var lines: [String] = []
    private var finished: [(id: UInt64, ms: Double)] = []
    private var samples: [UInt64: [String]] = [:]
    /// Preallocated: nothing may allocate while the main thread is suspended (it may hold malloc's lock).
    private let frames = UnsafeMutablePointer<UInt>.allocate(capacity: 64)

    private func locked<T>(_ body: () -> T) -> T {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return body()
    }

    private func signalIfIdle() -> Bool {
        guard idle else { return false }
        idle = false
        return true
    }

    func passBegan(_ now: TimeInterval) {
        let signal = locked { pass += 1; passStart = now; running = true; return signalIfIdle() }
        if signal { wake.signal() }
    }

    func passEnded(_ now: TimeInterval) {
        let signal = locked { () -> Bool in
            guard running else { return false }
            running = false
            let d = now - passStart
            guard d >= StallMonitor.threshold else { return false }
            finished.append((pass, d * 1000))
            return signalIfIdle()
        }
        if signal { wake.signal() }
    }

    func log(_ line: String) {
        let signal = locked { lines.append(line); return signalIfIdle() }
        if signal { wake.signal() }
    }

    func watch() {
        var sampled: (id: UInt64, count: Int) = (0, 0)
        while true {
            let (out, target) = locked { () -> (String, (id: UInt64, at: TimeInterval)?) in
                var out = lines.map { $0 + "\n" }.joined()
                lines = []
                for f in finished {
                    out += String(format: "stall %.1f ms\n", f.ms)
                    out += (samples.removeValue(forKey: f.id) ?? ["  (ended before a sample)\n"]).joined()
                }
                finished = []
                // Samples of passes that ended short of the threshold.
                samples = samples.filter { $0.key == pass }
                guard running else { idle = true; return (out, nil) }
                let n = sampled.id == pass ? sampled.count : 0
                return (out, (pass, passStart + StallMonitor.threshold + Double(n) * 0.1))
            }
            if !out.isEmpty { FileHandle.standardError.write(Data(out.utf8)) }
            guard let target else { wake.wait(); continue }
            if sampled.id != target.id { sampled = (target.id, 0) }
            let delay = target.at - ProcessInfo.processInfo.systemUptime
            if delay > 0 { usleep(useconds_t(delay * 1e6)) }
            let still = locked { running && pass == target.id }
            guard still, sampled.count < 10 else { continue }
            let into = (ProcessInfo.processInfo.systemUptime - locked { passStart }) * 1000
            let n = backtrace()
            let text = String(format: "  sample %.0f ms\n", into) + symbolicate(n)
            sampled.count += 1
            locked { if pass == target.id { samples[target.id, default: []].append(text) } }
        }
    }

    /// The main thread's return addresses, walked along its frame pointers while it is suspended.
    private func backtrace() -> Int {
        #if arch(arm64)
        guard thread_suspend(mainThread) == KERN_SUCCESS else { return 0 }
        defer { thread_resume(mainThread) }
        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<UInt32>.size)
        let kr = withUnsafeMutablePointer(to: &state) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(count)) { thread_get_state(mainThread, ARM_THREAD_STATE64, $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let strip: UInt = 0x0000_7FFF_FFFF_FFFF
        var n = 0
        frames[n] = UInt(state.__pc) & strip; n += 1
        frames[n] = UInt(state.__lr) & strip; n += 1
        var fp = UInt(state.__fp)
        var pair: (UInt, UInt) = (0, 0)
        while n < 64, fp != 0, fp & 7 == 0 {
            var got: vm_size_t = 0
            let ok = withUnsafeMutablePointer(to: &pair) {
                vm_read_overwrite(mach_task_self_, vm_address_t(fp), 16, vm_address_t(UInt(bitPattern: $0)), &got) == KERN_SUCCESS
            }
            guard ok, got == 16, pair.1 != 0 else { break }
            frames[n] = pair.1 & strip; n += 1
            guard pair.0 > fp else { break }
            fp = pair.0
        }
        return n
        #else
        return 0
        #endif
    }

    private func symbolicate(_ n: Int) -> String {
        var out = ""
        for i in 0..<min(n, 40) {
            let addr = frames[i]
            var info = Dl_info()
            guard dladdr(UnsafeRawPointer(bitPattern: addr), &info) != 0 else { out += String(format: "    0x%lx\n", addr); continue }
            let image = info.dli_fname.map { (String(cString: $0) as NSString).lastPathComponent } ?? "?"
            let base = UInt(bitPattern: info.dli_fbase)
            var name = info.dli_sname.map { String(cString: $0) } ?? ""
            if let demangled = demangle(name) { name = demangled }
            out += String(format: "    %@+0x%lx %@\n", image, addr - base, String(name.prefix(160)))
        }
        return out
    }
}

private typealias DemangleFn = @convention(c) (UnsafePointer<CChar>?, Int, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<Int>?, UInt32) -> UnsafeMutablePointer<CChar>?
private let swiftDemangle: DemangleFn? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_demangle").map { unsafeBitCast($0, to: DemangleFn.self) }

private func demangle(_ name: String) -> String? {
    guard name.hasPrefix("$s") || name.hasPrefix("_$s"), let swiftDemangle else { return nil }
    return name.withCString { c in
        guard let out = swiftDemangle(c, strlen(c), nil, nil, 0) else { return nil }
        defer { free(out) }
        return String(cString: out)
    }
}
