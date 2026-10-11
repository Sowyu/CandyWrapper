import AppKit
import DesignSystem

/// `ThreadStatusLine` (ThreadStatusLine.tsx:10-30): one quiet line after the last message for thread state that does
/// not change what Enter does: "Snoozed, in 2h · Wake now" or "Settled 5m ago · Un-settle". `gap-1.5 px-4 pb-2
/// text-xs text-muted-foreground`, a 14pt icon, the label, a dot, and an `InlineButton tone="muted"`.
public final class ThreadStatusLineView: DSView {
    public static let height: CGFloat = 16 + 8

    public var icon: IconName = .alarmClock { didSet { if icon != oldValue { rebuildIcon() } } }
    public var label = "" { didSet { text.text = label; needsLayout = true } }
    public var actionLabel = "" { didSet { action.label.text = actionLabel; needsLayout = true } }
    public var actionEnabled = true { didSet { action.isEnabled = actionEnabled } }
    public var onAction: (@MainActor () -> Void)? { didSet { action.action = onAction } }

    private var iconView = IconView(name: .alarmClock, size: 14)
    private let text = LabelView("", font: DSFont.ui(12))
    private let dot = LabelView("·", font: DSFont.ui(12))
    private let action = ThreadStatusLineAction()

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        text.lineHeight = 16
        dot.lineHeight = 16
        for v in [iconView, text, dot, action] as [NSView] { addSubview(v) }
        restyle()
    }

    private func rebuildIcon() {
        iconView.removeFromSuperview()
        iconView = IconView(name: icon, size: 14)
        addSubview(iconView)
        restyle()
        needsLayout = true
    }

    public override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); restyle() }

    private func restyle() {
        iconView.strokeColor = Themed.color(\.mutedForeground)
        text.color = Themed.color(\.mutedForeground)
        dot.color = Themed.color(\.mutedForeground)
    }

    public override func layout() {
        super.layout()
        var x: CGFloat = 16
        iconView.frame = NSRect(x: x, y: 1, width: 14, height: 14)
        x += 14 + 6
        let aw = action.preferredWidth, dw = ceil(dot.textWidth)
        let tw = min(ceil(text.textWidth), max(0, bounds.width - 16 - x - 6 - dw - 6 - aw))
        text.frame = NSRect(x: x, y: 0, width: tw, height: 16)
        x += tw + 6
        dot.frame = NSRect(x: x, y: 0, width: dw, height: 16)
        x += dw + 6
        action.frame = NSRect(x: x, y: 0, width: aw, height: 16)
    }
}

/// `InlineButton` (button.tsx:103-118): medium, underlined on hover, 64% disabled. `tone="muted"` is
/// muted and turns foreground on hover; the default tone stays foreground.
final class ThreadStatusLineAction: ControlView {
    enum Tone { case muted, foreground, primary }
    let label = LabelView("", font: DSFont.ui(12, weight: .medium))
    var tone = Tone.muted { didSet { restyle() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scalesWhenPressed = false
        label.lineHeight = 16
        addSubview(label)
        restyle()
    }

    var preferredWidth: CGFloat { ceil(label.textWidth) + 1 }

    override func layout() { super.layout(); label.frame = bounds }
    override func stateDidChange(from old: State) { super.stateDidChange(from: old); restyle() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); restyle() }

    private func restyle() {
        label.color = tone == .primary ? Themed.color(\.primary)
            : state.hovered || tone == .foreground ? Themed.color(\.foreground) : Themed.color(\.mutedForeground)
        label.isUnderlined = state.hovered
        setAccessibilityLabel(label.text)
    }
}
