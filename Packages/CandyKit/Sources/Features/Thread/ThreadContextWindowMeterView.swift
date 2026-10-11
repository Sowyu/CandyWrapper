import AppKit
import DesignSystem
import T3Protocol

/// contextWindow.ts:26-176. Live turn usage wins over provider usage and compaction history.
public struct ThreadContextWindowUsage: Equatable, Sendable {
    public var used: Double
    public var maximum: Double?
    public var total: Double?
    public var cost: Double?
    public var automatically: Bool
    public var percentage: Double? { maximum.flatMap { $0 > 0 ? min(100, max(0, used / $0 * 100)) : nil } }
    public static func derive(_ projection: ThreadProjection?) -> Self? {
        guard let projection else { return nil }
        func read(_ json: JSONValue, live: Bool) -> Self? {
            guard let used = json["usedTokens"]?.doubleValue, used.isFinite else { return nil }
            return Self(used: max(0, used), maximum: json["maxTokens"]?.doubleValue,
                        total: live ? nil : json["totalProcessedTokens"]?.doubleValue,
                        cost: live ? nil : json["cost"]?.doubleValue,
                        automatically: live || json["compactsAutomatically"]?.boolValue == true)
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
        toolTip = summary
        setAccessibilityLabel(summary)
    } }
    public var onCompact: (@MainActor () -> Void)?
    public var compactDisabledReason: String?
    public override var wantsUpdateLayer: Bool { false }
    public override var intrinsicContentSize: NSSize { NSSize(width: 28, height: 28) }
    public var summary: String {
        guard let usage else { return "Context Window" }
        return usage.percentageLabel.map { "Context window \($0) used" } ?? "Context window \(ThreadContextWindowUsage.tokens(usage.used)) tokens used"
    }
    public override init(frame: NSRect) {
        super.init(frame: frame)
        action = { [weak self] in self?.showDetails() }
    }
    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let usage else { return }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius: CGFloat = 9.75 * 20 / 24
        ctx.setLineWidth(2.5)
        ctx.setStrokeColor(Themed.color(\.mutedForeground, 0.24).cgColor(in: self))
        ctx.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        let fraction = (usage.percentage ?? 0) / 100
        guard fraction > 0 else { return }
        ctx.setStrokeColor((fraction > 0.9 ? Themed.color(\.destructive) : Themed.color(\.mutedForeground, 0.72)).cgColor(in: self))
        ctx.setLineCap(.round)
        ctx.addArc(center: center, radius: radius, startAngle: -.pi / 2, endAngle: -.pi / 2 + fraction * 2 * .pi, clockwise: false)
        ctx.strokePath()
    }
    private func showDetails() {
        guard let usage else { return }
        let content = ThreadContextWindowDetailsView(usage: usage, disabled: compactDisabledReason, compact: onCompact)
        let popover = PopoverView(content: content, padding: .compact, width: .sm)
        popover.show(from: self)
    }
}

private final class ThreadContextWindowDetailsView: DSView {
    private let label: TextBlockView
    private let compact = ButtonView("Compact context", icon: .minimize2, variant: .outline, size: .xs)
    init(usage: ThreadContextWindowUsage, disabled: String?, compact action: (@MainActor () -> Void)?) {
        var lines = ["Context Window", "\(usage.percentageLabel.map { $0 + " · " } ?? "")\(ThreadContextWindowUsage.tokens(usage.used))\(usage.maximum.map { "/" + ThreadContextWindowUsage.tokens($0) } ?? "")"]
        if let total = usage.total, total > 0 { lines.append("Total processed  \(ThreadContextWindowUsage.tokens(total))") }
        if let cost = usage.cost { lines.append(String(format: "Cost  $%.2f", cost)) }
        if usage.automatically { lines.append("Context compacts automatically.") }
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
