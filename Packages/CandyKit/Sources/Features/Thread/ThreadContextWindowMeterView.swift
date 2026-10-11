import AppKit
import DesignSystem
import T3Protocol

/// contextWindow.ts:26-176. Live turn usage wins over provider usage and compaction history.
public struct ThreadContextWindowUsage: Equatable, Sendable {
    public var used: Double
    public var maximum: Double?
    public var total: Double?
    public var cost: Double?
    public var currency: String = "USD"
    public var autoCompactThreshold: Double? = nil
    public var automatically: Bool
    public var percentage: Double? { maximum.flatMap { $0 > 0 ? min(100, max(0, used / $0 * 100)) : nil } }
    public static func derive(_ projection: ThreadProjection?) -> Self? {
        guard let projection else { return nil }
        func read(_ json: JSONValue, live: Bool) -> Self? {
            guard let used = json["usedTokens"]?.doubleValue, used.isFinite else { return nil }
            return Self(used: max(0, used), maximum: json["maxTokens"]?.doubleValue,
                        total: live ? nil : json["totalProcessedTokens"]?.doubleValue,
                        cost: live ? nil : (json["cost"]?.doubleValue ?? json["cost"]?["amount"]?.doubleValue),
                        currency: json["cost"]?["currency"]?.stringValue ?? "USD",
                        autoCompactThreshold: json["autoCompactThreshold"]?.doubleValue, automatically: live || json["compactsAutomatically"]?.boolValue == true)
        }
        for turn in projection.providerTurns.reversed() {
            if let usage = turn["tokenUsage"], let result = read(usage, live: true) { return result }
        }
        if let provider = projection.providerThreads.first(where: { $0["id"]?.stringValue == projection.thread.activeProviderThreadId }),
           let usage = provider["contextUsage"], let result = read(usage, live: false) { return result }
        for entry in projection.visibleTurnItems.reversed() {
            let item = entry.item.raw
            if item["type"]?.stringValue == "compaction", let used = item["afterTokenCount"]?.doubleValue, used >= 0 {
                return Self(used: used, total: item["beforeTokenCount"]?.doubleValue, automatically: true)
            }
        }
        return nil
    }
    public static func tokens(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        if value < 1_000 { return String(Int(value.rounded())) }
        if value < 10_000 { return decimal(value / 1_000) + "k" }
        if value < 1_000_000 { return String(Int((value / 1_000).rounded())) + "k" }
        return decimal(value / 1_000_000) + "m"
    }
    private static func decimal(_ value: Double) -> String {
        String(format: "%.1f", value).replacingOccurrences(of: ".0", with: "")
    }
    public var percentageLabel: String? { percentage.map { $0 < 10 ? Self.decimal($0) + "%" : "\(Int($0.rounded()))%" } }
}

/// ContextWindowMeter.tsx:42-211. No timer or idle animation; the stream changes the ring.
public final class ThreadContextWindowMeterView: ControlView {
    public var usage: ThreadContextWindowUsage? { didSet {
        guard usage != oldValue else { return }
        needsDisplay = true
        updateArc(animated: oldValue != nil)
        toolTip = summary
        setAccessibilityLabel(summary)
        setAccessibilityValue(usage?.percentage.map { NSNumber(value: $0) })
    } }
    public var onCompact: (@MainActor () -> Void)?
    private weak var detailsPopup: OpenPopup?
    public var modelDisplayName: String?
    public var compactDisabledReason: String?
    public override var wantsUpdateLayer: Bool { false }
    public override var intrinsicContentSize: NSSize { NSSize(width: 28, height: 28) }
    public var summary: String {
        guard let usage else { return "Context Window" }
        return usage.percentageLabel.map { "Context window \($0) used" } ?? "Context window \(ThreadContextWindowUsage.tokens(usage.used)) tokens used"
    }
    public override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityMinValue(0)
        setAccessibilityMaxValue(100)
        action = { [weak self] in self?.showDetails() }
        arc.actions = ["position": NSNull(), "bounds": NSNull(), "path": NSNull(), "strokeEnd": NSNull(), "strokeColor": NSNull(), "hidden": NSNull()]
        arc.fillColor = nil
        arc.lineWidth = 2.5
        arc.lineCap = .round
        arc.isHidden = true
        layer?.addSublayer(arc)
    }

    /// The usage arc as a layer, so its `stroke-dashoffset` and `stroke` changes run 500ms `ease-out`
    /// (ContextWindowMeter.tsx:82; Tailwind's `ease-out` is `cubic-bezier(0, 0, .2, 1)`).
    private let arc = CAShapeLayer()
    private static let easeOut = CAMediaTimingFunction(controlPoints: 0, 0, 0.2, 1)

    private func updateArc(animated: Bool) {
        let fraction = min(1, max(0, (usage?.percentage ?? 0) / 100))
        let color = (fraction > 0.9 ? Themed.color(\.destructive) : Themed.color(\.mutedForeground, 0.72)).cgColor(in: self)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if animated, !arc.isHidden, fraction > 0, window != nil, !Motion.reduced {
            Motion.animate(arc, keyPath: "strokeEnd", to: fraction, duration: 0.5, timing: Self.easeOut)
            Motion.animate(arc, keyPath: "strokeColor", to: color, duration: 0.5, timing: Self.easeOut)
        }
        arc.isHidden = fraction <= 0
        arc.strokeEnd = fraction
        arc.strokeColor = color
        CATransaction.commit()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateArc(animated: false)
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let usage else { return }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius: CGFloat = 9.75 * 20 / 24
        ctx.setLineWidth(2.5)
        ctx.setStrokeColor(Themed.color(\.mutedForeground, 0.24).cgColor(in: self))
        ctx.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    public override func layout() {
        super.layout()
        // A full turn from the top, clockwise on screen (y grows downward here); `strokeEnd` is the share used.
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let path = CGMutablePath()
        path.addArc(center: center, radius: 9.75 * 20 / 24, startAngle: -.pi / 2, endAngle: 3 * .pi / 2, clockwise: false)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arc.frame = bounds
        arc.path = path
        CATransaction.commit()
    }
    public override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        showDetails()
    }
    public override func viewDidMoveToWindow() {
        if window == nil, let detailsPopup { detailsPopup.content.popupHost?.close(detailsPopup) }
        super.viewDidMoveToWindow()
    }
    private func showDetails() {
        guard detailsPopup == nil else { return }
        guard let usage else { return }
        let content = ThreadContextWindowDetailsView(usage: usage, model: modelDisplayName, disabled: compactDisabledReason, compact: onCompact)
        let popover = PopoverView(content: content, padding: .compact, width: .sm)
        detailsPopup = popover.show(from: self, placement: PopupPlacement(side: .top, align: .end, sideOffset: 4))
    }
}

private final class ThreadContextWindowDetailsView: DSView {
    private let label: TextBlockView
    private let compact = ButtonView("Compact context", icon: .minimize2, variant: .outline, size: .xs)
    init(usage: ThreadContextWindowUsage, model: String?, disabled: String?, compact action: (@MainActor () -> Void)?) {
        var lines = ["Context Window", "\(usage.percentageLabel.map { $0 + " · " } ?? "")\(ThreadContextWindowUsage.tokens(usage.used))\(usage.maximum.map { "/" + ThreadContextWindowUsage.tokens($0) } ?? "")"]
        if let total = usage.total, total > 0 { lines.append("Total processed  \(ThreadContextWindowUsage.tokens(total))") }
        if let cost = usage.cost { lines.append("Cost  " + usage.currency + " " + String(format: abs(cost) > 0 && abs(cost) < 0.01 ? "%.4f" : "%.2f", cost)) }
        if usage.automatically {
            if let threshold = usage.autoCompactThreshold, threshold > 0, threshold < 9e15 {
                lines.append("Compacts automatically at " + Int(threshold).formatted(.number.locale(Locale(identifier: "en_US"))) + " tokens.")
            } else { lines.append(model.map { "Context for " + $0 + " compacts automatically when needed." } ?? "Context compacts automatically when needed.") }
        }
        if let disabled { lines.append(disabled) }
        label = TextBlockView(lines.joined(separator: "\n"), font: DSFont.ui(11), lineHeight: 18, color: Themed.color(\.mutedForeground))
        super.init(frame: .zero)
        addSubview(label); addSubview(compact)
        compact.isEnabled = disabled == nil && action != nil
        compact.action = action
        frame.size = NSSize(width: 230, height: CGFloat(lines.count) * 18 + 34)
    }
    override var intrinsicContentSize: NSSize { frame.size }
    override func layout() {
        super.layout()
        label.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - 30)
        compact.frame = NSRect(x: 0, y: bounds.height - 24, width: bounds.width, height: 24)
    }
}
