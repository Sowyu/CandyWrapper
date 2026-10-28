import AppKit
import DesignSystem

/// The Compact chip left of the send button (ComposerPrimaryActions.tsx:357-397): `h-7 rounded-full border
/// px-2.5 gap-1.5 text-xs tabular-nums`, the minimize icon at 14, "Compact" or "Keep" and the token count.
/// On it is `border-warning/40 text-warning` with a `warning/8` hover fill; off it is `border-border
/// text-muted-foreground` that turns `foreground` on hover. Colors fade over 150ms (`transition-colors`).
final class ComposerCompactPill: ControlView {
    /// The formatted count, "123k".
    var tokens = "" { didSet { if tokens != oldValue { restyle() } } }
    /// The chip is off: the next send keeps full history.
    var keepFullHistory = false { didSet { if keepFullHistory != oldValue { restyle() } } }

    private var modern: Bool { ComposerDesign.uses3814(dark: effectiveAppearance.isDark) }

    static let height: CGFloat = 28
    private let icon = IconView(name: .minimize2, size: 14, strokeColor: Themed.color(\.warning))
    private let word = LabelView("", font: SB.tabular(12), color: Themed.color(\.warning))
    private let count = LabelView("", font: SB.tabular(12), color: Themed.color(\.warning))
    private let decoration = BoxDecorationLayer()
    private lazy var tip = TooltipController.attach(to: self, text: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scalesWhenPressed = false
        transitions = .colors
        decoration.host = self
        layer?.insertSublayer(decoration, at: 0)
        for label in [word, count] {
            label.lineHeight = 16
            // Text on the composer's glass skips font smoothing, like Chromium (PROGRESS findings).
            label.smoothsFont = false
            addSubview(label)
        }
        addSubview(icon)
        restyle()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: (modern ? 8 + 16 + 6 + ceil(word.textWidth) + 6 + ceil(count.textWidth) + 8 : 1 + 10 + 14 + 6 + ceil(word.textWidth) + 6 + ceil(count.textWidth) + 10 + 1), height: Self.height)
    }

    override func layout() {
        super.layout()
        decoration.frame = bounds
        decoration.layout(boxSize: bounds.size)
        var x: CGFloat = modern ? 8 : 11
        let glyph: CGFloat = modern ? 16 : 14
        icon.frame = NSRect(x: x, y: ((bounds.height - glyph) / 2).rounded(), width: glyph, height: glyph)
        x += glyph + 6
        let ww = ceil(word.textWidth)
        let line: CGFloat = modern ? 20 : 16
        word.frame = NSRect(x: x, y: ((bounds.height - line) / 2).rounded(), width: ww, height: line)
        x += ww + 6
        count.frame = NSRect(x: x, y: word.frame.minY, width: ceil(count.textWidth), height: line)
    }

    override func stateDidChange(from old: State) {
        super.stateDidChange(from: old)
        restyle()
    }

    private func restyle() {
        // T3 3814 ComposerPrimaryActions.tsx:374-375 keeps the count visible in both modes.
        word.font = modern ? DSFont.ui(14, weight: .medium) : SB.tabular(12)
        count.font = modern ? SB.tabular(14, .medium) : SB.tabular(12)
        word.lineHeight = modern ? 20 : 16; count.lineHeight = modern ? 20 : 16
        word.text = keepFullHistory ? "Keep" : "Compact"
        count.text = tokens
        let hovered = state.hovered && state.enabled
        let ink = keepFullHistory ? Themed.color(hovered ? \.foreground : \.mutedForeground) : Themed.color(\.warning)
        for label in [word, count] { label.color = ink }
        icon.strokeColor = ink
        var box = BoxStyle()
        box.radius = Self.height / 2
        box.border = keepFullHistory ? Themed.color(\.border) : Themed.color(\.warning, 0.4)
        box.fill = !keepFullHistory && hovered ? Themed.color(\.warning, 0.08) : nil
        if modern {
            word.color = Themed.color(\.foreground, hovered || !keepFullHistory ? 1 : 0.8)
            count.color = Themed.color(\.mutedForeground); icon.strokeColor = Themed.color(\.mutedForeground)
            box.radius = 8; box.border = nil
            box.fill = hovered ? Themed.color(\.accent) : !keepFullHistory ? Themed.color(\.accent, 0.6) : nil
        }
        decoration.boxStyle = box
        // Two lines (ComposerPrimaryActions.tsx:389-396).
        tip.text = keepFullHistory
            ? "Next send keeps all \(tokens) tokens.\nClick to compact first"
            : "Next send compacts \(tokens) tokens first.\nClick to keep full history"
        setAccessibilityLabel("Compact \(tokens) tokens of history before sending")
        setAccessibilityValue(NSNumber(value: !keepFullHistory))
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        decoration.setNeedsDisplay()
    }

    override func resetCursorRects() { if state.enabled { addCursorRect(bounds, cursor: .pointingHand) } }
}
