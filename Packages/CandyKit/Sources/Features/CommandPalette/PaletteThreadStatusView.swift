import AppKit
import DesignSystem
import T3Store

/// ThreadStatusIndicators.tsx:617-655,659-746, shown before a command palette thread title.
/// These are resting dots: the palette never starts a timer for a status badge.
public final class PaletteThreadStatusView: DSView {
    private let label: LabelView
    private let dot = CALayer()
    private let dotColor: NSColor
    public init(_ status: ThreadStatusPill) {
        let color: NSColor
        switch status.label {
        case .pendingApproval: color = Self.color("amber", dot: false)
        case .planReady: color = Self.color("violet", dot: false)
        case .awaitingInput: color = Self.color("indigo", dot: false)
        case .failed: color = Themed.color(\.destructive)
        case .completed: color = Self.color("emerald", dot: false)
        default: color = Themed.color(\.mutedForeground)
        }
        let stem = status.label == .pendingApproval ? "amber" : status.label == .completed ? "emerald" : status.label == .awaitingInput ? "indigo" : status.label == .planReady ? "violet" : nil
        dotColor = stem.map { Self.color($0, dot: true) } ?? color
        label = LabelView(status.label.rawValue, font: DSFont.ui(10), color: color)
        super.init(frame: .zero)
        label.lineHeight = 14
        addSubview(label)
        dot.backgroundColor = dotColor.cgColor(in: self)
        dot.cornerRadius = 3
        dot.actions = ["frame": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(dot)
        setAccessibilityLabel(status.label.rawValue)
    }
    private static func color(_ stem: String, dot: Bool) -> NSColor {
        Themed.pick(light: Themed.base(stem + (dot ? "-500" : "-600")), dark: Themed.base(stem + "-300").withAlphaComponent(0.9))
    }
    public override var intrinsicContentSize: NSSize { NSSize(width: 10 + ceil(label.textWidth), height: 14) }
    public override func layout() {
        super.layout()
        dot.frame = CGRect(x: 0, y: 4, width: 6, height: 6)
        dot.backgroundColor = dotColor.cgColor(in: self)
        label.frame = NSRect(x: 10, y: 0, width: max(0, bounds.width - 10), height: 14)
    }
}
