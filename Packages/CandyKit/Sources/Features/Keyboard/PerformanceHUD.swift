import AppKit
import Darwin

/// The kernel's counters for this process (`proc_pid_rusage`), the ones `scripts/procstat` reads.
public struct ProcessSample: Equatable, Sendable {
    /// User plus system CPU time, in nanoseconds.
    public var cpuNanos: UInt64
    /// `phys_footprint`, what Activity Monitor calls Memory.
    public var footprint: UInt64
    /// Interrupt plus package idle wakeups.
    public var wakeups: UInt64
    /// Monotonic seconds.
    public var time: TimeInterval

    public init(cpuNanos: UInt64, footprint: UInt64, wakeups: UInt64, time: TimeInterval) {
        self.cpuNanos = cpuNanos; self.footprint = footprint; self.wakeups = wakeups; self.time = time
    }

    public static func current() -> ProcessSample? {
        var info = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        guard ok == 0 else { return nil }
        // The rusage times are mach ticks (41.67 ns on Apple Silicon), not nanoseconds.
        let ticks = info.ri_user_time + info.ri_system_time
        let cpu = ticks.multipliedReportingOverflow(by: UInt64(timebase.numer)).partialValue / UInt64(max(1, timebase.denom))
        return ProcessSample(cpuNanos: cpu, footprint: info.ri_phys_footprint,
                             wakeups: info.ri_interrupt_wkups + info.ri_pkg_idle_wkups, time: ProcessInfo.processInfo.systemUptime)
    }

    private static let timebase: mach_timebase_info_data_t = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return tb
    }()
}

/// One line of the HUD, from two samples.
public struct PerformanceReading: Equatable, Sendable {
    /// Percent of one core.
    public var cpu: Double
    public var footprintMB: Double
    /// The longest main run loop pass, from wake to sleep, in ms: layout, drawing and the
    /// Core Animation commit of a frame all happen inside one.
    public var frameMs: Double
    public var wakeupsPerSecond: Double
    public var eventsPerSecond: Double

    public init(from a: ProcessSample, to b: ProcessSample, events: Int, frameMs: Double) {
        let seconds = max(0.001, b.time - a.time)
        cpu = Double(b.cpuNanos &- a.cpuNanos) / 1e9 / seconds * 100
        footprintMB = Double(b.footprint) / 1_048_576
        self.frameMs = frameMs
        wakeupsPerSecond = Double(b.wakeups &- a.wakeups) / seconds
        eventsPerSecond = Double(events) / seconds
    }

    public var text: String {
        String(format: "CPU %5.1f%%  RAM %6.1f MB\nframe %5.1f ms  wake %5.1f/s  events %5.1f/s",
               cpu, footprintMB, frameMs, wakeupsPerSecond, eventsPerSecond)
    }
}

/// The spec's performance HUD: a hidden overlay with CPU, RAM, frame time, wakeups and server
/// events per second. Hidden, it has no view, timer or observer. Shown, it samples every 0.5 s,
/// and only while the window can be seen.
@MainActor
public final class PerformanceHUD {
    public static let interval: TimeInterval = 0.5

    private let events: () -> Int
    private let setCounting: (Bool) -> Void
    private var view: PerformanceHUDView?
    private var timer: Timer?
    private var occlusion: NSObjectProtocol?
    private var observer: CFRunLoopObserver?
    private var last: ProcessSample?
    private var passStart: CFTimeInterval = 0
    private var longestPass: CFTimeInterval = 0

    /// `events` returns the server messages since its last call; `setCounting` turns that count on and off.
    public init(events: @escaping () -> Int, setCounting: @escaping (Bool) -> Void) {
        self.events = events
        self.setCounting = setCounting
    }

    public var isShown: Bool { view != nil }
    /// For tests: whether a sampling timer exists.
    public var isSampling: Bool { timer != nil }
    public var text: String? { view?.text }

    public func toggle(in host: NSView) {
        if isShown { hide() } else { show(in: host) }
    }

    public func show(in host: NSView) {
        guard view == nil else { return }
        let view = PerformanceHUDView()
        view.frame = NSRect(x: host.bounds.maxX - PerformanceHUDView.size.width - 12, y: host.isFlipped ? 48 : host.bounds.maxY - 48 - PerformanceHUDView.size.height,
                            width: PerformanceHUDView.size.width, height: PerformanceHUDView.size.height)
        view.autoresizingMask = host.isFlipped ? [.minXMargin, .maxYMargin] : [.minXMargin, .minYMargin]
        host.addSubview(view)
        self.view = view
        setCounting(true)
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue,
                                                          true, 0) { [weak self] _, activity in
            MainActor.assumeIsolated { self?.runLoop(activity) }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
        if let window = host.window {
            occlusion = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateTimer() }
            }
        }
        updateTimer()
    }

    public func hide() {
        timer?.invalidate(); timer = nil
        if let observer { CFRunLoopObserverInvalidate(observer) }
        observer = nil
        if let occlusion { NotificationCenter.default.removeObserver(occlusion) }
        occlusion = nil
        view?.removeFromSuperview(); view = nil
        last = nil
        setCounting(false)
    }

    private func runLoop(_ activity: CFRunLoopActivity) {
        let now = CACurrentMediaTime()
        if activity == .afterWaiting { passStart = now } else if passStart > 0 { longestPass = max(longestPass, now - passStart) }
    }

    private func updateTimer() {
        let visible = view?.window.map { $0.isVisible && $0.occlusionState.contains(.visible) } ?? false
        if visible, timer == nil {
            last = ProcessSample.current(); _ = events(); longestPass = 0
            let t = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.sample() } }
            t.tolerance = Self.interval / 10
            RunLoop.main.add(t, forMode: .common)
            timer = t
            view?.text = "CPU     -  RAM      -\nframe     -  wake     -  events     -"
        } else if !visible {
            timer?.invalidate(); timer = nil
        }
    }

    private func sample() {
        guard let now = ProcessSample.current() else { return }
        if let last {
            view?.text = PerformanceReading(from: last, to: now, events: events(), frameMs: longestPass * 1000).text
        }
        last = now
        longestPass = 0
    }
}

/// White monospaced text on a dark rounded box. It never takes clicks.
final class PerformanceHUDView: NSView {
    static let size = NSSize(width: 330, height: 40)
    private static let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
        .foregroundColor: NSColor.white,
    ]

    var text = "" {
        didSet {
            guard text != oldValue else { return }
            setAccessibilityLabel(text)
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.backgroundColor = NSColor(white: 0, alpha: 0.78).cgColor
        layer?.cornerRadius = 6
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        (text as NSString).draw(in: bounds.insetBy(dx: 8, dy: 5), withAttributes: Self.attributes)
    }
}
