import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// session-logic.ts:260-281 and ComposerTasksBadge.tsx:13-222.
public struct ThreadTaskStep: Equatable, Sendable {
    public var text: String
    public var status: String
    public var durationMs: Int?
    public init(text: String, status: String, durationMs: Int? = nil) {
        self.text = text; self.status = status; self.durationMs = durationMs
    }
    public static func derive(_ projection: ThreadProjection?) -> [Self] {
        guard let projection else { return [] }
        let plans = projection.plans.filter { $0.kind == "todo_list" }
        let plan = plans.last { $0.runId == projection.runs.last?.id } ?? plans.last
        return plan?.steps?.arrayValue?.compactMap { value in
            guard let text = value["text"]?.stringValue, let status = value["status"]?.stringValue else { return nil }
            return Self(text: text, status: status, durationMs: value["durationMs"]?.intValue)
        } ?? []
    }
    public static func summary(_ steps: [Self]) -> String {
        steps.first { $0.status == "running" }?.text ?? steps.first { $0.status == "pending" }?.text ?? steps.last?.text ?? ""
    }
}

/// A static segmented badge and a bounded, scrollable task drawer. No clock while idle.
public final class ThreadTasksView: ComposerBannerView {
    public var onHeightChange: (() -> Void)?
    public var steps: [ThreadTaskStep] = [] { didSet {
        guard steps != oldValue else { return }
        header.steps = steps
        rebuild(); needsLayout = true; onHeightChange?()
    } }
    public private(set) var expanded = false
    let header = ThreadTasksHeaderRow()
    private let scroller = NSScrollView()
    private let body = DSView()
    private var labels: [ThreadTaskStepView] = []
    public init() {
        super.init(variant: .neutral)
        addSubview(header); addSubview(scroller)
        scroller.documentView = body; scroller.drawsBackground = false
        scroller.useT3Scrollbars(.overlay) // ComposerBanner.Scroll is a ScrollArea (ComposerTasksBadge.tsx:162)
        header.action = { [weak self] in
            guard let self else { return }
            expanded.toggle(); header.expanded = expanded; rebuild(); needsLayout = true; onHeightChange?()
        }
    }
    public var height: CGFloat { 34 + Self.overlap + (expanded ? min(240, labels.reduce(8) { $0 + $1.height(forWidth: max(1, bounds.width - 32)) }) : 0) }
    private func rebuild() {
        labels.forEach { $0.removeFromSuperview() }; labels = []
        scroller.isHidden = !expanded
        guard expanded else { return }
        for step in steps {
            let label = ThreadTaskStepView(step: step)
            body.addSubview(label); labels.append(label)
        }
    }
    public override func layout() {
        super.layout()
        // `@min-[560px]:flex` on the segments, against the banner's own width.
        header.showsSegments = bounds.width >= 560
        header.frame = NSRect(x: 0, y: 5, width: bounds.width, height: 24)
        scroller.frame = NSRect(x: 8, y: 34, width: bounds.width - 16, height: max(0, bounds.height - 34 - tail))
        let width = scroller.contentSize.width
        var y: CGFloat = 4
        for label in labels {
            let h = label.height(forWidth: max(1, width - 8))
            label.frame = NSRect(x: 4, y: y, width: max(1, width - 8), height: h)
            y += h
        }
        body.frame = NSRect(x: 0, y: 0, width: width, height: y + 4)
    }
}

/// `TaskSummary` in a `ComposerBanner.Row` button (ComposerTasksBadge.tsx:65-96, ComposerBanner.tsx:190-337):
/// the list icon, "Tasks" and the current step truncating in the content column, then the count, the segments and
/// the toggle. Placed at the reference capture's offsets (thread-completion/tasks-*).
final class ThreadTasksHeaderRow: ControlView {
    var steps: [ThreadTaskStep] = [] { didSet { if steps != oldValue { update() } } }
    var expanded = false { didSet { if expanded != oldValue { update() } } }
    var showsSegments = false { didSet { if showsSegments != oldValue { needsLayout = true } } }
    let icon = IconView(name: .listTodo, size: 12, strokeColor: Themed.color(\.mutedForeground))
    private let tasks = bannerLabel(Themed.color(\.mutedForeground))
    let step = bannerLabel(Themed.color(\.foreground, 0.8), weight: .medium)
    let count = bannerLabel(Themed.color(\.mutedForeground), weight: .medium, tabular: true)
    /// `ChevronDownIcon`, turned 180 degrees while folded (ComposerBanner.tsx:328-337).
    private let chevron = IconView(name: .chevronDown, size: 14, strokeColor: Themed.color(\.foreground))
    private let chevronUp = IconView(name: .chevronUp, size: 14, strokeColor: Themed.color(\.foreground))
    private let segments = DSView()
    private var segmentLayers: [CALayer] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scalesWhenPressed = false
        tasks.text = "Tasks"
        [icon, tasks, step, count, segments, chevron, chevronUp].forEach(addSubview)
        setAccessibilityRole(.button)
        update()
    }

    private func update() {
        let done = steps.filter { $0.status == "completed" }.count
        let summary = ThreadTaskStep.summary(steps)
        step.text = summary
        count.text = "\(done)/\(steps.count)"
        count.color = Themed.color(done >= steps.count ? \.success : \.mutedForeground)
        chevron.isHidden = !expanded
        chevronUp.isHidden = expanded
        setAccessibilityLabel("\(expanded ? "Collapse tasks" : "Tasks"): \(done) of \(steps.count) complete. Current task: \(summary)")
        // `MAX_TASK_SEGMENTS`: one bar per step for 2 to 10 steps (ComposerTasksBadge.tsx:37-58).
        let wanted = steps.count > 1 && steps.count <= 10 ? steps.count : 0
        if segmentLayers.count != wanted {
            segmentLayers.forEach { $0.removeFromSuperlayer() }
            segmentLayers = (0..<wanted).map { _ in
                let l = CALayer(); l.cornerRadius = 1.5; l.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull()]
                segments.layer?.addSublayer(l); return l
            }
        }
        needsDisplay = true
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        icon.frame = NSRect(x: 8, y: 6, width: 12, height: 12)
        // Actions, `gap-1`: the count centred in at least 24, the 80pt segments, the toggle box.
        chevron.frame = NSRect(x: w - 21, y: 5, width: 14, height: 14)
        chevronUp.frame = chevron.frame
        var right = w - 24
        segments.isHidden = !showsSegments || segmentLayers.isEmpty
        if !segments.isHidden {
            segments.frame = NSRect(x: right - 80, y: 10.5, width: 80, height: 3)
            right -= 80 + 4
        } else {
            right -= 4
        }
        let tw = ceil(count.textWidth), cw = max(24, tw)
        count.frame = NSRect(x: right - cw + (cw - tw) / 2, y: 4, width: tw + 1, height: 16)
        // Content, `gap-1`: "Tasks" keeps its width, the step truncates.
        let contentRight = right - cw - 4
        let lw = ceil(tasks.textWidth)
        tasks.frame = NSRect(x: 36, y: 4, width: lw + 1, height: 16)
        step.frame = NSRect(x: 36 + lw + 4, y: 4, width: max(0, contentRight - (36 + lw + 4)), height: 16)
        let segmentWidth = (80 - CGFloat(max(0, segmentLayers.count - 1)) * 2) / CGFloat(max(1, segmentLayers.count))
        for (i, layer) in segmentLayers.enumerated() { layer.frame = NSRect(x: CGFloat(i) * (segmentWidth + 2), y: 0, width: segmentWidth, height: 3) }
    }

    override func updateLayer() {
        super.updateLayer()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (i, layer) in segmentLayers.enumerated() where i < steps.count {
            let status = steps[i].status
            layer.backgroundColor = Themed.color(status == "completed" ? \.success : status == "running" ? \.primary : \.mutedForeground,
                                                 status == "pending" ? 0.25 : 1).cgColor(in: self)
        }
        CATransaction.commit()
    }
}

/// Labels on the glass draw without font smoothing, like Chromium on backdrop-filter layers.
@MainActor private func bannerLabel(_ color: NSColor, weight: NSFont.Weight = .regular, tabular: Bool = false) -> LabelView {
    let label = LabelView("", font: tabular ? SB.tabular(12, weight) : DSFont.ui(12, weight: weight), color: color)
    label.lineHeight = 16
    label.smoothsFont = false
    return label
}

/// ComposerTasksBadge.tsx:166-218. Wrapped task text and source status glyphs.
final class ThreadTaskStepView: DSView {
    private let text: TextBlockView
    private let duration: LabelView
    private let icon: IconView
    init(step: ThreadTaskStep) {
        let running = step.status == "running", done = step.status == "completed"
        text = TextBlockView(step.text, font: DSFont.ui(12), lineHeight: 16,
            color: Themed.color(running ? \.foreground : \.mutedForeground, running ? 0.9 : done ? 0.55 : 0.7))
        duration = LabelView(step.durationMs.map { formatDuration(Double($0)) } ?? (running ? "now" : ""),
            font: DSFont.ui(10), color: Themed.color(\.mutedForeground, 0.45))
        icon = IconView(name: done ? .check : running ? .circleDot : .circle, size: 12)
        super.init(frame: .zero)
        icon.strokeColor = Themed.color(done ? \.success : running ? \.primary : \.mutedForeground, done || running ? 1 : 0.4)
        [text, duration, icon].forEach(addSubview)
        setAccessibilityElement(true)
        setAccessibilityLabel("\(done ? "Completed" : running ? "Running" : "Pending"): \(step.text) \(duration.text)")
    }
    /// `min-w-12 whitespace-nowrap`: a duration over an hour widens its column instead of wrapping (9b7e7dff45).
    private var durationWidth: CGFloat { max(48, ceil(duration.textWidth)) }
    func height(forWidth width: CGFloat) -> CGFloat { max(16, text.height(forWidth: max(1, width - 40 - durationWidth))) + 8 }
    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 6, y: 6, width: 12, height: 12)
        text.frame = NSRect(x: 28, y: 4, width: max(1, bounds.width - 40 - durationWidth), height: bounds.height - 8)
        duration.frame = NSRect(x: bounds.width - 4 - durationWidth, y: 4, width: durationWidth, height: 16)
    }
}
