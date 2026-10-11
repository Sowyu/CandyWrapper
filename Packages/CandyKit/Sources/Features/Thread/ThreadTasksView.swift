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
// ponytail: single-line task labels and static durations, port wrapped rows and duration formatting before full badge parity.
public final class ThreadTasksView: ComposerBannerView {
    public var onHeightChange: (() -> Void)?
    public var steps: [ThreadTaskStep] = [] { didSet {
        guard steps != oldValue else { return }
        summary.title = "Tasks   \(ThreadTaskStep.summary(steps))"
        summary.setAccessibilityLabel("Tasks: \(steps.filter { $0.status == "completed" }.count) of \(steps.count) complete")
        rebuild(); needsDisplay = true; needsLayout = true; onHeightChange?()
    } }
    public private(set) var expanded = false
    private let summary = ButtonView("Tasks", icon: .listTodo, variant: .ghost, size: .sm)
    private let count = LabelView("", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    private let chevron = ButtonView(icon: .chevronDown, variant: .ghost, size: .iconXs)
    private let segments = DSView()
    private var segmentLayers: [CALayer] = []
    private let scroller = NSScrollView()
    private let body = DSView()
    private var labels: [LabelView] = []
    public init() {
        super.init(variant: .neutral)
        addSubview(summary); addSubview(count); addSubview(scroller); addSubview(segments); addSubview(chevron)
        scroller.documentView = body; scroller.drawsBackground = false
        scroller.hasVerticalScroller = true; scroller.autohidesScrollers = true
        summary.action = { [weak self] in
            guard let self else { return }
            expanded.toggle(); chevron.icon = expanded ? .chevronUp : .chevronDown; rebuild(); needsLayout = true; onHeightChange?()
        }
        chevron.action = summary.action
    }
    public var height: CGFloat { 34 + Self.overlap + (expanded ? min(240, CGFloat(steps.count) * 28 + 8) : 0) }
    private func rebuild() {
        labels.forEach { $0.removeFromSuperview() }; labels = []
        count.text = "\(steps.filter { $0.status == "completed" }.count)/\(steps.count)"
        count.color = Themed.color(steps.allSatisfy { $0.status == "completed" } ? \.success : \.mutedForeground)
        segmentLayers.forEach { $0.removeFromSuperlayer() }
        segmentLayers = steps.count > 1 && steps.count <= 10 ? steps.map { _ in let l = CALayer(); l.cornerRadius = 1.5; segments.layer?.addSublayer(l); return l } : []
        needsDisplay = true
        scroller.isHidden = !expanded
        guard expanded else { return }
        for step in steps {
            let mark = step.status == "completed" ? "✓" : step.status == "running" ? "◉" : "○"
            let duration = step.durationMs.map { "  \($0 / 1000)s" } ?? (step.status == "running" ? "  now" : "")
            let label = LabelView("\(mark)  \(step.text)\(duration)", font: DSFont.ui(12), color: Themed.color(step.status == "running" ? \.foreground : \.mutedForeground))
            label.toolTip = step.text; body.addSubview(label); labels.append(label)
        }
    }
    public override func layout() {
        super.layout()
        let segmented = !segmentLayers.isEmpty && bounds.width >= 560
        segments.isHidden = !segmented
        summary.frame = NSRect(x: 4, y: 4, width: max(0, bounds.width - (segmented ? 174 : 86)), height: 26)
        count.frame = NSRect(x: bounds.width - (segmented ? 164 : 76), y: 9, width: 44, height: 18)
        chevron.frame = NSRect(x: bounds.width - 28, y: 5, width: 24, height: 24)
        segments.frame = NSRect(x: bounds.width - 116, y: 16, width: 80, height: 3)
        let segmentWidth = (80 - CGFloat(max(0, segmentLayers.count - 1)) * 2) / CGFloat(max(1, segmentLayers.count))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (i, layer) in segmentLayers.enumerated() { layer.frame = NSRect(x: CGFloat(i) * (segmentWidth + 2), y: 0, width: segmentWidth, height: 3) }
        CATransaction.commit()
        scroller.frame = NSRect(x: 8, y: 34, width: bounds.width - 16, height: max(0, height - 34 - Self.overlap))
        body.frame = NSRect(x: 0, y: 0, width: scroller.contentSize.width, height: CGFloat(labels.count) * 28)
        for (i, label) in labels.enumerated() { label.frame = NSRect(x: 4, y: CGFloat(i) * 28, width: body.bounds.width - 8, height: 24) }
    }
    public override func updateLayer() {
        super.updateLayer()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (i, layer) in segmentLayers.enumerated() {
            let step = steps[i]
            layer.backgroundColor = Themed.color(step.status == "completed" ? \.success : step.status == "running" ? \.primary : \.mutedForeground, step.status == "pending" ? 0.25 : 1).cgColor(in: self)
        }
        CATransaction.commit()
    }
}
