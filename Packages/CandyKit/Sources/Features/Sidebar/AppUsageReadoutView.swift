import AppKit
import Darwin
import DesignSystem

/// One reading of this process: CPU time so far, the uptime it was read at, and the physical footprint.
public struct AppUsageSample: Equatable, Sendable {
    public var cpuSeconds: Double
    public var uptime: Double
    public var footprint: UInt64

    /// Reads this process through mach `task_info`: CPU from the live threads (`TASK_THREAD_TIMES_INFO`) plus the
    /// ended ones (`MACH_TASK_BASIC_INFO`), memory from `TASK_VM_INFO`'s `phys_footprint`, Activity Monitor's Memory.
    public static func read() -> AppUsageSample? {
        func info<T>(_ flavor: Int32, _ value: inout T) -> Bool {
            var count = mach_msg_type_number_t(MemoryLayout<T>.size / MemoryLayout<natural_t>.size)
            return withUnsafeMutablePointer(to: &value) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(flavor), $0, &count) }
            } == KERN_SUCCESS
        }
        var basic = mach_task_basic_info(), threads = task_thread_times_info(), vm = task_vm_info_data_t()
        guard info(MACH_TASK_BASIC_INFO, &basic), info(TASK_THREAD_TIMES_INFO, &threads), info(TASK_VM_INFO, &vm) else { return nil }
        func s(_ t: time_value_t) -> Double { Double(t.seconds) + Double(t.microseconds) / 1_000_000 }
        let cpu = s(basic.user_time) + s(basic.system_time) + s(threads.user_time) + s(threads.system_time)
        return AppUsageSample(cpuSeconds: cpu, uptime: ProcessInfo.processInfo.systemUptime, footprint: vm.phys_footprint)
    }
}

/// What the readout shows for two samples: the numbers, the meters' lit dots and the tooltip.
public enum AppUsageLogic {
    public static let dots = 6
    /// The memory meter fills at 1 GB.
    public static let memoryScale: Double = 1_073_741_824
    /// CPU turns amber after this many samples in a row above `hotPercent`.
    public static let hotPercent: Double = 50
    public static let hotSamples = 2

    /// CPU over the interval as a percent of one core; 0 when no time passed.
    public static func cpuPercent(from a: AppUsageSample, to b: AppUsageSample) -> Double {
        let wall = b.uptime - a.uptime
        guard wall > 0 else { return 0 }
        return max(0, (b.cpuSeconds - a.cpuSeconds) / wall * 100)
    }

    public static func cpuText(_ percent: Double) -> String {
        percent < 9.95 ? String(format: "%.1f%%", percent) : String(format: "%.0f%%", percent)
    }

    public static func memoryText(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1_048_576
        return mb < 999.5 ? String(format: "%.0fM", mb) : String(format: "%.1fG", mb / 1024)
    }

    /// Lit dots for a 0...1 level: rounded, and at least one while there is any.
    public static func lit(_ fraction: Double) -> Int {
        guard fraction > 0 else { return 0 }
        return min(dots, max(1, Int((fraction * Double(dots)).rounded())))
    }

    public static func tooltip(cpu: Double?, footprint: UInt64) -> String {
        let c = cpu.map { "\(cpuText($0)) of one core" } ?? "measuring"
        return "CandyWrapper CPU \(c) · Memory \(String(format: "%.0f", Double(footprint) / 1_048_576)) MB"
    }
}

/// A short row of dots, Redesign's working grid laid flat: `lit` of them in the foreground, the rest faint. A change
/// fades the dots that flip one after another, toward the new level.
final class AppUsageMeterView: DSView {
    static let dot: CGFloat = 2, gap: CGFloat = 1
    static var width: CGFloat { CGFloat(AppUsageLogic.dots) * dot + CGFloat(AppUsageLogic.dots - 1) * gap }
    private var dots: [CALayer] = []
    private(set) var lit = 0
    var hot = false { didSet { if hot != oldValue { needsDisplay = true } } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for _ in 0..<AppUsageLogic.dots {
            let d = CALayer()
            d.actions = ["bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull()]
            d.cornerRadius = Self.dot / 2
            layer?.addSublayer(d)
            dots.append(d)
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        let y = ((bounds.height - Self.dot) / 2).rounded()
        for (i, d) in dots.enumerated() { d.frame = CGRect(x: CGFloat(i) * (Self.dot + Self.gap), y: y, width: Self.dot, height: Self.dot) }
    }

    func setLit(_ n: Int, animated: Bool) {
        guard n != lit else { return }
        let old = lit
        lit = n
        let now = CACurrentMediaTime(), up = n > old
        for i in (min(old, n)..<max(old, n)) where animated && !Motion.reduced {
            let a = CABasicAnimation(keyPath: "backgroundColor")
            a.fromValue = color(i < old)
            a.duration = 0.18
            a.beginTime = now + 0.04 * Double(up ? i - old : old - 1 - i)
            a.fillMode = .backwards
            dots[i].add(a, forKey: "level")
        }
        needsDisplay = true
    }

    private func color(_ on: Bool) -> CGColor {
        on ? (hot ? SB.c(\.warning) : SB.c(\.sidebarForeground, 0.85)).cgColor(in: self) : SB.c(\.sidebarForeground, 0.2).cgColor(in: self)
    }

    override func updateLayer() {
        for (i, d) in dots.enumerated() { d.backgroundColor = color(i < lit) }
    }
}

/// Redesign's account pill second line: CandyWrapper's own CPU and memory, each an icon, a dot meter and a short
/// number. It samples only while the app is active, the window shows and the sidebar is open.
public final class AppUsageReadoutView: DSView {
    static let interval: TimeInterval = 5
    private let cpuIcon = IconView(name: .cpu, size: 12)
    private let memoryIcon = IconView(name: .memoryStick, size: 12)
    let cpuMeter = AppUsageMeterView()
    let memoryMeter = AppUsageMeterView()
    let cpuLabel = LabelView("–", font: SB.font(11).monospacedDigits, color: SB.c(\.sidebarMutedForeground))
    let memoryLabel = LabelView("–", font: SB.font(11).monospacedDigits, color: SB.c(\.sidebarMutedForeground))
    /// The layout's sidebar is open; a closed one slides out of view without hiding.
    public var sidebarOpen = true { didSet { if sidebarOpen != oldValue { sync() } } }
    private var timer: Timer?
    private var last: AppUsageSample?
    private var hotStreak = 0
    private var observers: [NSObjectProtocol] = []
    private var occlusion: NSObjectProtocol?
    var isSampling: Bool { timer != nil }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for v: NSView in [cpuIcon, cpuMeter, cpuLabel, memoryIcon, memoryMeter, memoryLabel] { addSubview(v) }
        for l in [cpuLabel, memoryLabel] { l.lineHeight = 16 }
        let center = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.sync() } })
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    isolated deinit {
        for o in observers + [occlusion].compactMap({ $0 }) { NotificationCenter.default.removeObserver(o) }
        timer?.invalidate()
    }

    public override var wantsUpdateLayer: Bool { true }

    public override func updateLayer() {
        for i in [cpuIcon, memoryIcon] { i.strokeColor = SB.c(\.sidebarMutedForeground) }
    }

    public override func layout() {
        super.layout()
        var x: CGFloat = 0
        let h = bounds.height
        for (icon, meter, label) in [(cpuIcon, cpuMeter, cpuLabel), (memoryIcon, memoryMeter, memoryLabel)] {
            icon.frame = NSRect(x: x, y: (h - 12) / 2, width: 12, height: 12)
            meter.frame = NSRect(x: x + 12 + 3, y: 0, width: AppUsageMeterView.width, height: h)
            let lx = meter.frame.maxX + 3, w = ceil(label.textWidth)
            label.frame = NSRect(x: lx, y: (h - 16) / 2, width: min(w, max(0, bounds.width - lx)), height: 16)
            x = lx + w + 8
        }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusion { NotificationCenter.default.removeObserver(occlusion) }
        occlusion = window.map { window in
            NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sync() }
            }
        }
        sync()
    }

    public override func viewDidHide() { super.viewDidHide(); sync() }
    public override func viewDidUnhide() { super.viewDidUnhide(); sync() }

    private func sync() {
        let visible = window.map { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) } ?? false
        let run = visible && NSApp.isActive && !isHiddenOrHasHiddenAncestor && sidebarOpen
        guard run != (timer != nil) else { return }
        guard run else { timer?.invalidate(); timer = nil; return }
        sample(animated: false)
        // ponytail: 5s sampling while visible, event-driven if it shows in perf-review
        let t = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.sample(animated: true) } }
        t.tolerance = 1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Takes a reading and shows it; the CPU number is the average since the last reading.
    func sample(animated: Bool) {
        guard let now = AppUsageSample.read() else { return }
        let cpu = last.flatMap { $0.uptime < now.uptime ? AppUsageLogic.cpuPercent(from: $0, to: now) : nil }
        last = now
        show(cpu: cpu, footprint: now.footprint, animated: animated)
    }

    func show(cpu: Double?, footprint: UInt64, animated: Bool) {
        if let cpu {
            hotStreak = cpu > AppUsageLogic.hotPercent ? hotStreak + 1 : 0
            cpuMeter.hot = hotStreak >= AppUsageLogic.hotSamples
            cpuMeter.setLit(AppUsageLogic.lit(cpu / 100), animated: animated)
            cpuLabel.text = AppUsageLogic.cpuText(cpu)
        }
        memoryMeter.setLit(AppUsageLogic.lit(Double(footprint) / AppUsageLogic.memoryScale), animated: animated)
        memoryLabel.text = AppUsageLogic.memoryText(footprint)
        let tip = AppUsageLogic.tooltip(cpu: cpu, footprint: footprint)
        if toolTip != tip { toolTip = tip; setAccessibilityValue(tip) }
        needsLayout = true
    }
}
