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

/// What the readout shows for two samples: the numbers, the meters' levels and the tooltip.
public enum AppUsageLogic {
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
        return mb < 999.5 ? String(format: "%.0f MB", mb) : String(format: "%.1f GB", mb / 1024)
    }

    /// A meter's filled share for a 0...1 reading: capped at full, and never less than `Meter.least` while there is any.
    public static func level(_ fraction: Double) -> CGFloat {
        guard fraction > 0 else { return 0 }
        return min(1, max(RedesignTokens.Meter.least, CGFloat(fraction)))
    }

    public static func tooltip(cpu: Double?, footprint: UInt64) -> String {
        // One line per meter, saying what it measures and where its bar is full.
        let c = cpu.map { "\(cpuText($0)) of one core, the bar full at one core" } ?? "measuring"
        return "CandyWrapper's own use\nCPU: \(c)\nMemory: \(String(format: "%.0f", Double(footprint) / 1_048_576)) MB, the bar full at 1 GB"
    }
}

/// A short bar on a faint track, filled to `level`, so it reads as a scale at a glance. A change moves the fill's
/// right end over `RedesignTokens.Motion.standard` on the layer, and only then.
final class AppUsageMeterView: DSView {
    typealias M = RedesignTokens.Meter
    static var width: CGFloat { M.width }
    private let track = CALayer()
    private let fill = CALayer()
    private(set) var level: CGFloat = 0
    var hot = false { didSet { if hot != oldValue { needsDisplay = true } } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for l in [track, fill] {
            l.actions = ["bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull()]
            l.cornerRadius = M.height / 2
            layer?.addSublayer(l)
        }
        fill.anchorPoint = CGPoint(x: 0, y: 0.5)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private var fillWidth: CGFloat { (M.width * level).rounded() }

    override func layout() {
        super.layout()
        let y = ((bounds.height - M.height) / 2).rounded()
        track.frame = CGRect(x: 0, y: y, width: M.width, height: M.height)
        fill.bounds = CGRect(x: 0, y: 0, width: fillWidth, height: M.height)
        fill.position = CGPoint(x: 0, y: y + M.height / 2)
    }

    func setLevel(_ new: CGFloat, animated: Bool) {
        guard new != level else { return }
        let from = fill.presentation()?.bounds.width ?? fillWidth
        level = new
        fill.bounds.size.width = fillWidth
        if animated, !Motion.reduced, window != nil {
            let a = CABasicAnimation(keyPath: "bounds.size.width")
            a.fromValue = from
            a.toValue = fillWidth
            a.duration = RedesignTokens.Motion.standard
            a.timingFunction = RedesignTokens.Motion.curve
            fill.add(a, forKey: "level")
        }
    }

    override func updateLayer() {
        track.backgroundColor = SB.c(\.sidebarForeground, M.track).cgColor(in: self)
        fill.backgroundColor = (hot ? SB.c(\.warning) : SB.c(\.sidebarForeground, M.fill)).cgColor(in: self)
    }
}

/// Redesign's account pill second line: CandyWrapper's own CPU and memory, each an icon, a bar meter and a short
/// number in tabular digits. A reading shows only once it exists, so the line is empty, never a dash, before the
/// first one. It samples every `interval` only while the app is active, the window shows and the sidebar is open;
/// a visible window in the background takes one memory reading when it appears.
public final class AppUsageReadoutView: DSView {
    static let interval: TimeInterval = 5
    /// Icon to bar, bar to number.
    static let gap: CGFloat = 4
    /// CPU's number to memory's icon.
    static let segmentGap: CGFloat = 10
    private let cpuIcon = IconView(name: .cpu, size: 12)
    private let memoryIcon = IconView(name: .memoryStick, size: 12)
    let cpuMeter = AppUsageMeterView()
    let memoryMeter = AppUsageMeterView()
    let cpuLabel = LabelView("", font: SB.font(11).monospacedDigits, color: SB.c(\.sidebarMutedForeground))
    let memoryLabel = LabelView("", font: SB.font(11).monospacedDigits, color: SB.c(\.sidebarMutedForeground))
    /// Some reading shows. Without one the account card centres the name on its own.
    public var hasReading: Bool { !memoryLabel.text.isEmpty || !cpuLabel.text.isEmpty }
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
        let h = bounds.height, g = Self.gap
        let all = [(cpuIcon, cpuMeter, cpuLabel), (memoryIcon, memoryMeter, memoryLabel)]
        for (icon, meter, label) in all where label.text.isEmpty { icon.isHidden = true; meter.isHidden = true; label.isHidden = true }
        let segments = all.filter { !$0.2.text.isEmpty }
        // In a narrow sidebar the meters go first, so the numbers and units never truncate.
        let full = segments.reduce(-Self.segmentGap) { $0 + 12 + g + AppUsageMeterView.width + g + ceil($1.2.textWidth) + Self.segmentGap }
        let meters = full <= bounds.width
        for (icon, meter, label) in segments {
            icon.frame = NSRect(x: x, y: (h - 12) / 2, width: 12, height: 12)
            meter.isHidden = !meters
            meter.frame = NSRect(x: x + 12 + g, y: 0, width: meters ? AppUsageMeterView.width : 0, height: h)
            let lx = meters ? meter.frame.maxX + g : x + 12 + g, w = ceil(label.textWidth)
            label.frame = NSRect(x: lx, y: (h - 16) / 2, width: w, height: 16)
            // Narrower still, a reading that would be cut ("1" of "182 MB") goes with its icon.
            let fits = lx + w <= bounds.width
            icon.isHidden = !fits
            label.isHidden = !fits
            if !fits { meter.isHidden = true }
            x = lx + w + Self.segmentGap
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
        // A window behind another app, covered or not, has no reading yet: one memory reading, with no timer and no
        // CPU baseline, so the card never shows an empty meter.
        if !run, !hasReading, window?.isVisible == true, !isHiddenOrHasHiddenAncestor, sidebarOpen, let now = AppUsageSample.read() {
            show(cpu: nil, footprint: now.footprint, animated: false)
        }
        guard run != (timer != nil) else { return }
        // A fresh baseline on every resume, so the first reading isn't averaged over the hidden stretch.
        guard run else { timer?.invalidate(); timer = nil; last = nil; hotStreak = 0; return }
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
        let had = hasReading
        if let cpu {
            hotStreak = cpu > AppUsageLogic.hotPercent ? hotStreak + 1 : 0
            cpuMeter.hot = hotStreak >= AppUsageLogic.hotSamples
            // The first CPU reading appears in place; later ones move the bar.
            cpuMeter.setLevel(AppUsageLogic.level(cpu / 100), animated: animated && !cpuLabel.text.isEmpty)
            cpuLabel.text = AppUsageLogic.cpuText(cpu)
        }
        memoryMeter.setLevel(AppUsageLogic.level(Double(footprint) / AppUsageLogic.memoryScale), animated: animated && had)
        memoryLabel.text = AppUsageLogic.memoryText(footprint)
        let tip = AppUsageLogic.tooltip(cpu: cpu, footprint: footprint)
        if currentTooltip != tip { setTooltip(tip); setAccessibilityValue(tip) }
        needsLayout = true
        if !had { superview?.needsLayout = true }
    }
}
