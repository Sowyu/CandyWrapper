import AppKit
import DesignSystem

/// The list header of a subagent thread (MessagesTimeline.tsx:1409-1437): `TimelineSystemDivider` with an action,
/// "Subagent of · {parent title}" in a 26pt pill between two `border/70` rules, under the lane's `pt-2`.
/// A click opens the parent (TimelineSystemDivider.tsx:35-66).
public final class TimelineParentLinkView: DSView {
    public static let height: CGFloat = 8 + 8 + 26 + 8

    public var parentTitle = "" { didSet { detail.text = "·\u{00a0}" + parentTitle; needsLayout = true } }
    /// Nil makes the divider a plain `rounded-full px-2 py-1` label instead of the bordered button
    /// (TimelineSystemDivider.tsx:73-82), as in an embedded side chat.
    public var onOpen: (@MainActor () -> Void)? { didSet { pill.action = onOpen; if (onOpen == nil) != (oldValue == nil) { updateKind() } } }
    /// Redesign only: a delegated task (another agent started it and you can message it) reads "Task from", the
    /// provider's own subagents keep "Subagent of" and their status bar instead of a composer.
    public var delegated = false { didSet { if delegated != oldValue { updateKind() } } }
    /// A side chat's divider: "Context from" with the chat-bubbles glyph.
    public var sideChat = false { didSet { if sideChat != oldValue { updateKind() } } }
    private var tooltip: TooltipController?

    private let leftRule = CALayer(), rightRule = CALayer()
    private let pill = TimelineParentLinkPill()
    private var icon = IconView(name: .bot, size: 12)
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
        tooltip = TooltipController.attach(to: pill, text: "Open parent thread", placement: PopupPlacement(side: .top, align: .center, sideOffset: 4))
    }

    private func updateKind() {
        let task = delegated && ThemeRuntime.isDither(dark: effectiveAppearance.isDark)
        label.text = sideChat ? "Context from" : task ? "Task from" : "Subagent of"
        tooltip?.text = onOpen == nil ? "" : task ? "Another agent started this task. You can message it below to steer it. Click to open the parent."
            : "Open parent thread"
        if icon.name != (sideChat ? .messagesSquare : .bot) {
            icon.removeFromSuperview()
            icon = IconView(name: sideChat ? .messagesSquare : .bot, size: 12)
            pill.addSubview(icon)
        }
        pill.isPlain = onOpen == nil
        pill.setAccessibilityLabel(onOpen == nil ? nil : "Open parent thread")
        needsLayout = true
        needsDisplay = true
    }

    public override func layout() {
        super.layout()
        let lw = ceil(label.textWidth), dw = min(320, ceil(detail.textWidth))
        // `px-2.5 py-1 gap-1.5`, a 1pt border: icon, label, then the detail capped at `max-w-80`.
        let pad: CGFloat = onOpen == nil ? 8 : 11
        let pw = min(bounds.width - 32, 2 * pad + 12 + 6 + lw + 6 + dw)
        let x = ((bounds.width - pw) / 2).rounded()
        let top: CGFloat = 8 + 8
        pill.frame = NSRect(x: x, y: top, width: pw, height: 26)
        icon.frame = NSRect(x: pad, y: 7, width: 12, height: 12)
        label.frame = NSRect(x: pad + 12 + 6, y: 5, width: lw, height: 16)
        detail.frame = NSRect(x: label.frame.maxX + 6, y: 5, width: max(0, pw - pad - label.frame.maxX - 6), height: 16)
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

    public override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateKind(); needsDisplay = true }
}

/// The divider's button: `rounded-full border border-border/70 bg-background`, `hover:bg-muted`.
final class TimelineParentLinkPill: ControlView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scalesWhenPressed = false
        transitions = .colors // transition-colors (TimelineSystemDivider.tsx:51)
        layer?.borderWidth = 1
    }
    /// No action: no border, no fill and no hover.
    var isPlain = false { didSet { isEnabled = !isPlain; layer?.borderWidth = isPlain ? 0 : 1; needsDisplay = true } }
    override func layout() { super.layout(); layer?.cornerRadius = bounds.height / 2 }
    override func stateDidChange(from old: State) { super.stateDidChange(from: old); needsDisplay = true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.borderColor = Themed.color(\.border, 0.7).cgColor(in: self)
        Motion.setBackground(layer, isPlain ? nil : (state.hovered ? Themed.color(\.muted) : Themed.color(\.background)).cgColor(in: self))
    }
}
