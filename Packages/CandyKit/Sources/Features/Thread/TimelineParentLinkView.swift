import AppKit
import DesignSystem

/// The list header of a subagent thread (MessagesTimeline.tsx:1409-1437): `TimelineSystemDivider` with an action,
/// "Subagent of · {parent title}" in a 26pt pill between two `border/70` rules, under the lane's `pt-2`.
/// A click opens the parent (TimelineSystemDivider.tsx:35-66).
public final class TimelineParentLinkView: DSView {
    public static let height: CGFloat = 8 + 8 + 26 + 8

    public var parentTitle = "" { didSet { detail.text = "·\u{00a0}" + parentTitle; needsLayout = true } }
    public var onOpen: (@MainActor () -> Void)? { didSet { pill.action = onOpen } }

    private let leftRule = CALayer(), rightRule = CALayer()
    private let pill = TimelineParentLinkPill()
    private let icon = IconView(name: .bot, size: 12)
    private let label = LabelView("Subagent of", font: DSFont.ui(11, weight: .medium))
    private let detail = LabelView("", font: DSFont.ui(11))

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for r in [leftRule, rightRule] {
            r.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull()]
            layer?.addSublayer(r)
        }
        label.lineHeight = 16
        detail.lineHeight = 16
        detail.alphaValue = 0.7
        addSubview(pill)
        for v in [icon, label, detail] as [NSView] { pill.addSubview(v) }
        pill.setAccessibilityLabel("Open parent thread")
        _ = TooltipController.attach(to: pill, text: "Open parent thread", placement: PopupPlacement(side: .top, align: .center, sideOffset: 4))
    }

    public override func layout() {
        super.layout()
        let lw = ceil(label.textWidth), dw = min(320, ceil(detail.textWidth))
        // `px-2.5 py-1 gap-1.5`, a 1pt border: icon, label, then the detail capped at `max-w-80`.
        let pw = min(bounds.width - 32, 1 + 10 + 12 + 6 + lw + 6 + dw + 10 + 1)
        let x = ((bounds.width - pw) / 2).rounded()
        let top: CGFloat = 8 + 8
        pill.frame = NSRect(x: x, y: top, width: pw, height: 26)
        icon.frame = NSRect(x: 11, y: 7, width: 12, height: 12)
        label.frame = NSRect(x: 11 + 12 + 6, y: 5, width: lw, height: 16)
        detail.frame = NSRect(x: label.frame.maxX + 6, y: 5, width: max(0, pw - 11 - label.frame.maxX - 6), height: 16)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        leftRule.frame = CGRect(x: 0, y: top + 13, width: max(0, x - 8), height: 1)
        rightRule.frame = CGRect(x: x + pw + 8, y: top + 13, width: max(0, bounds.width - x - pw - 8), height: 1)
        CATransaction.commit()
    }

    public override var wantsUpdateLayer: Bool { true }
    public override func updateLayer() {
        let rule = Themed.color(\.border, 0.7).cgColor(in: self)
        leftRule.backgroundColor = rule
        rightRule.backgroundColor = rule
        let muted = Themed.color(\.mutedForeground)
        icon.strokeColor = muted
        label.color = muted
        detail.color = muted
    }

    public override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

/// The divider's button: `rounded-full border border-border/70 bg-background`, `hover:bg-muted`.
final class TimelineParentLinkPill: ControlView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scalesWhenPressed = false
        transitions = .colors // transition-colors (TimelineSystemDivider.tsx:51)
        layer?.borderWidth = 1
    }
    override func layout() { super.layout(); layer?.cornerRadius = bounds.height / 2 }
    override func stateDidChange(from old: State) { super.stateDidChange(from: old); needsDisplay = true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.borderColor = Themed.color(\.border, 0.7).cgColor(in: self)
        Motion.setBackground(layer, (state.hovered ? Themed.color(\.muted) : Themed.color(\.background)).cgColor(in: self))
    }
}
