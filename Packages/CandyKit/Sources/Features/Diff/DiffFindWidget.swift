import AppKit
import DesignSystem

/// The diff's find widget: @pierre/diffs 1.5.2's `[data-search-panel]` in find mode with T3's colors
/// (`--diffs-search-panel-bg: var(--popover)`, `-fg: var(--popover-foreground)`, `-accent: var(--primary)`,
/// index.css:2111-2114). Geometry and colors were read from the widget T3 2861 renders: a 38pt-tall box with
/// a 200pt field, the case, word and regex toggles inside the field's end, the match count, previous and next,
/// and a round close button centered on the top-right corner.
final class DiffFindWidget: DSView {
    let field = InputView(placeholder: "Search", size: .find)
    let matchCase = DiffFindButton(DiffFindGlyphs.matchCase, label: "Match Case", size: 20)
    let wholeWord = DiffFindButton(DiffFindGlyphs.wholeWord, label: "Whole Word", size: 20)
    let regex = DiffFindButton(DiffFindGlyphs.regex, label: "Regexp", size: 20)
    let previous = DiffFindButton(DiffFindGlyphs.arrowRight, label: "Previous", size: 24, rotation: -.pi / 2)
    let next = DiffFindButton(DiffFindGlyphs.arrowRight, label: "Next", size: 24, rotation: .pi / 2)
    let close = DiffFindButton(DiffFindGlyphs.close, label: "Close", size: 20, round: true)
    private let count = LabelView("", font: DSFont.ui(12, weight: .medium))
    private let box = BoxDecorationLayer(), fieldBox = BoxDecorationLayer()

    /// The close button's half overhangs the box; the view keeps that room above and to the right.
    static let overhang: CGFloat = 10
    static let fieldWidth: CGFloat = 200, gap: CGFloat = 6, inset: CGFloat = 5, navWidth: CGFloat = 48

    /// `1 of 3`, or `No results` in the dimmer `[data-no-matches]` color.
    var countText = "" {
        didSet { count.text = countText; needsLayout = true; superview?.needsLayout = true; updateLayer() }
    }
    var hasMatches = false { didSet { previous.isEnabled = hasMatches; next.isEnabled = hasMatches; updateLayer() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        box.outset = 32
        for l in [box, fieldBox] { l.host = self; layer?.addSublayer(l) }
        field.unstyled = true
        field.paddingOverride = (6, 72)
        field.setAccessibilityLabel("Search")
        count.lineHeight = 20
        for v in [field, matchCase, wholeWord, regex, count, previous, next, close] as [NSView] { addSubview(v) }
        previous.isEnabled = false
        next.isEnabled = false
        field.onStateChange = { [weak self] _ in self?.updateLayer() }
    }

    @MainActor required init?(coder: NSCoder) { fatalError() }

    private var countWidth: CGFloat { max(50, ceil(count.textWidth)) }
    /// The box: border 1, padding 4, then field, count and nav on a 6pt grid gap.
    var boxSize: CGSize {
        CGSize(width: 2 * Self.inset + Self.fieldWidth + Self.gap + countWidth + Self.gap + Self.navWidth, height: 38)
    }
    var preferredSize: CGSize { CGSize(width: boxSize.width + Self.overhang, height: boxSize.height + Self.overhang) }

    override func layout() {
        super.layout()
        let box = CGRect(origin: CGPoint(x: 0, y: Self.overhang), size: boxSize)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.box.layout(boxSize: box.size)
        self.box.frame.origin.y += box.minY
        let x = box.minX + Self.inset, y = box.minY + Self.inset
        fieldBox.layout(boxSize: CGSize(width: Self.fieldWidth, height: 28))
        fieldBox.frame.origin.x += x
        fieldBox.frame.origin.y += y
        CATransaction.commit()
        field.frame = NSRect(x: x + 1, y: y + 1, width: Self.fieldWidth - 2, height: 26)
        // `[data-search-toggles]`: 4pt from the field's end, 1pt apart, centered.
        for (i, toggle) in [matchCase, wholeWord, regex].enumerated() {
            toggle.frame = NSRect(x: x + Self.fieldWidth - 4 - 62 + CGFloat(i) * 21, y: y + 4, width: 20, height: 20)
        }
        let countX = x + Self.fieldWidth + Self.gap
        count.frame = NSRect(x: countX, y: y + 4, width: countWidth, height: 20)
        let navX = countX + countWidth + Self.gap
        previous.frame = NSRect(x: navX, y: y + 2, width: 24, height: 24)
        next.frame = NSRect(x: navX + 24, y: y + 2, width: 24, height: 24)
        // `top: 0; right: 0; transform: translate(50%, -50%)` on the padding box's corner.
        close.frame = NSRect(x: box.maxX - 1 - 10, y: box.minY + 1 - 10, width: 20, height: 20)
    }

    override func updateLayer() {
        let fg = Themed.color(\.popoverForeground), bg = Themed.color(\.popover)
        // `border: 1px solid` fg at 20% over what lies behind (`background-clip: padding-box`), `--diffs-widget-shadow`.
        var style = BoxStyle()
        style.radius = 9
        style.fill = OKLab.mix(fg, 0.04, bg)
        style.backgroundClip = .padding
        style.border = fg.withAlphaComponent(0.2)
        let shade = NSColor.black.withAlphaComponent(CGFloat(0x13) / 255)
        style.shadows = [BoxShadow(spread: 1, color: bg, inset: true), BoxShadow(y: 4, blur: 8, color: shade), BoxShadow(y: 6, blur: 18, color: shade)]
        box.boxStyle = style
        // `border: 1px solid color-mix(in lab, fg 12%, bg)`; focused, `outline: 1px solid var(--diffs-modified-base)` outside it.
        var input = BoxStyle()
        input.radius = 6
        input.fill = bg
        input.border = OKLab.mix(fg, 0.12, bg)
        input.shadows = field.state.focused ? [BoxShadow(spread: 1, color: Themed.color(\.primary))] : []
        fieldBox.boxStyle = input
        count.color = OKLab.mix(fg, hasMatches ? 0.5 : 0.35, bg)
    }
}

/// `[data-search-icon]`: a 12pt glyph in a 20 or 24pt button, `color-mix(in lab, fg 65%, bg)`, the foreground on hover,
/// the accent while pressed (`aria-pressed`), a quarter opacity when disabled. The close button is round, filled with
/// `color-mix(in lab, fg 50%, bg)` and draws its glyph in the widget's background; hovered, it fills with the foreground.
final class DiffFindButton: DSView {
    private let glyph = CAShapeLayer()
    private let round: Bool
    private var hovered = false { didSet { if hovered != oldValue { updateLayer() } } }
    var isPressed = false { didSet { if isPressed != oldValue { updateLayer(); setAccessibilityValue(isPressed ? "on" : "off") } } }
    var isEnabled = true { didSet { alphaValue = isEnabled ? 1 : 0.25; updateLayer() } }
    var action: (() -> Void)?

    init(_ path: String, label: String, size: CGFloat, rotation: CGFloat = 0, round: Bool = false) {
        self.round = round
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        glyph.actions = ["fillColor": NSNull(), "position": NSNull(), "bounds": NSNull()]
        // The 16-unit viewBox drawn at 12pt, centered.
        var t = CGAffineTransform(translationX: (size - 12) / 2, y: (size - 12) / 2).scaledBy(x: 12 / 16, y: 12 / 16)
        if rotation != 0 { t = t.translatedBy(x: 8, y: 8).rotated(by: rotation).translatedBy(x: -8, y: -8) }
        glyph.path = (try? SVGPath.parse(path))?.copy(using: &t)
        glyph.frame = bounds
        layer?.addSublayer(glyph)
        layer?.cornerRadius = round ? size / 2 : 4
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
    }

    @MainActor required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        let fg = Themed.color(\.popoverForeground), bg = Themed.color(\.popover)
        let widgetBg = OKLab.mix(fg, 0.04, bg)
        let live = isEnabled && hovered
        let color: NSColor, fill: NSColor?
        if round {
            color = widgetBg
            fill = live ? fg : OKLab.mix(fg, 0.5, bg)
        } else {
            color = isPressed ? Themed.color(\.primary) : live ? fg : OKLab.mix(fg, 0.65, bg)
            fill = nil
        }
        // `transition: background-color .1s, color .1s`.
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.1)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            glyph.fillColor = color.cgColor
            layer?.backgroundColor = fill?.cgColor
        }
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    /// pierre's icons are plain `<button>`s with an `onclick` that never refocuses the field (fileTreeExpansion
    /// `Ee`'s `w` and `T`), and Chromium focuses a button on press, so a click on a toggle, Previous or Next
    /// takes the keyboard from the Search field.
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) { if isEnabled { window?.makeFirstResponder(self) } }
    override func mouseUp(with event: NSEvent) {
        guard isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        action?()
    }
    override func resetCursorRects() { if isEnabled { addCursorRect(bounds, cursor: .pointingHand) } }
    override func accessibilityPerformPress() -> Bool { guard isEnabled else { return false }; action?(); return true }
}
