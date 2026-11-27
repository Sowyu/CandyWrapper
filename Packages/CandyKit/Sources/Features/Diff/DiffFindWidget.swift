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
    /// Redesign's close: a ghost icon button inside the box after Next, as the thread find bar's, in place of pierre's
    /// round button on the corner. It runs `close.action`.
    private let ghostClose = ButtonView(icon: .x, variant: .ghost, size: .iconXs)
    /// Redesign's previous and next: the thread find bar's chevrons, so the app has one find bar. They run the arrows' actions.
    private let ghostPrevious = ButtonView(icon: .chevronUp, variant: .ghost, size: .iconXs)
    private let ghostNext = ButtonView(icon: .chevronDown, variant: .ghost, size: .iconXs)
    private var redesign: Bool { ThemeRuntime.isDither(dark: effectiveAppearance.isDark) }
    private var closeWidth: CGFloat { redesign ? 2 + 24 : 0 }
    /// Redesign's bar is the thread find bar's height.
    static let redesignHeight: CGFloat = 36

    /// The count as the thread find bar writes it: `2/5`, `0/0` when nothing matches, nothing before a query.
    static func compactCount(_ text: String, query: String) -> String {
        if query.isEmpty { return "" }
        if text == "No results" { return "0/0" }
        let parts = text.components(separatedBy: " of ")
        return parts.count == 2 ? parts.joined(separator: "/") : text
    }
    private func syncCount() {
        let shown = redesign ? Self.compactCount(countText, query: field.text) : countText
        if count.text != shown { count.text = shown }
        count.font = DSFont.ui(12, weight: redesign ? .regular : .medium)
    }
    private let count = LabelView("", font: DSFont.ui(12, weight: .medium))
    private let box = BoxDecorationLayer(), fieldBox = BoxDecorationLayer()

    /// The close button's half overhangs the box; the view keeps that room above and to the right.
    static let overhang: CGFloat = 10
    static let fieldWidth: CGFloat = 200, gap: CGFloat = 6, inset: CGFloat = 5, navWidth: CGFloat = 48
    /// The room the host gives it. A narrow pane shrinks the field, down to the toggles plus a little text.
    var availableWidth: CGFloat = .greatestFiniteMagnitude { didSet { if availableWidth != oldValue { needsLayout = true } } }
    private var fieldWidth: CGFloat {
        let fixed = 2 * Self.inset + Self.gap + countWidth + Self.gap + Self.navWidth + closeWidth + Self.overhang
        return max(80, min(Self.fieldWidth, availableWidth - fixed))
    }
    /// Below this the case, word and regex toggles leave the field too little room, so they hide.
    private var showsToggles: Bool { fieldWidth >= 140 }

    /// `1 of 3`, or `No results` in the dimmer `[data-no-matches]` color.
    var countText = "" {
        didSet { syncCount(); needsLayout = true; superview?.needsLayout = true; updateLayer() }
    }
    var hasMatches = false {
        didSet {
            for b in [previous, next] { b.isEnabled = hasMatches }
            for b in [ghostPrevious, ghostNext] { b.isEnabled = hasMatches }
            updateLayer()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        box.outset = 32
        for l in [box, fieldBox] { l.host = self; layer?.addSublayer(l) }
        field.unstyled = true
        field.paddingOverride = (6, 72)
        field.setAccessibilityLabel("Search")
        count.lineHeight = 20
        for v in [field, matchCase, wholeWord, regex, count, previous, next, close, ghostPrevious, ghostNext, ghostClose] as [NSView] { addSubview(v) }
        ghostClose.setAccessibilityLabel("Close")
        TooltipController.redesign(ghostClose, "Close find") { "Esc" }
        ghostClose.action = { [weak self] in self?.close.action?() }
        ghostPrevious.setAccessibilityLabel("Previous match")
        ghostNext.setAccessibilityLabel("Next match")
        TooltipController.redesign(ghostPrevious, "Previous match") { "⇧Return" }
        TooltipController.redesign(ghostNext, "Next match") { "Return" }
        ghostPrevious.action = { [weak self] in self?.previous.action?() }
        ghostNext.action = { [weak self] in self?.next.action?() }
        // The case, word and regex toggles name themselves in Redesign too.
        TooltipController.redesign(matchCase, "Match case")
        TooltipController.redesign(wholeWord, "Match whole word")
        TooltipController.redesign(regex, "Use regular expression")
        for b in [ghostPrevious, ghostNext] { b.isEnabled = false }
        previous.isEnabled = false
        next.isEnabled = false
        field.onStateChange = { [weak self] _ in self?.updateLayer() }
    }

    @MainActor required init?(coder: NSCoder) { fatalError() }

    private var countWidth: CGFloat { max(redesign ? 40 : 50, ceil(count.textWidth)) }
    /// The box: border 1, padding 4, then field, count and nav on a 6pt grid gap. Redesign: the thread find bar's
    /// 36pt row, the field straight on the bar, then the count and three 24pt buttons 2pt apart.
    var boxSize: CGSize {
        if redesign { return CGSize(width: fieldWidth + countWidth + 3 * 26 + 5, height: Self.redesignHeight) }
        return CGSize(width: 2 * Self.inset + fieldWidth + Self.gap + countWidth + Self.gap + Self.navWidth + closeWidth, height: 38)
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
        fieldBox.layout(boxSize: CGSize(width: fieldWidth, height: 28))
        fieldBox.frame.origin.x += x
        fieldBox.frame.origin.y += y
        CATransaction.commit()
        field.frame = NSRect(x: x + 1, y: y + 1, width: fieldWidth - 2, height: 26)
        // `[data-search-toggles]`: 4pt from the field's end, 1pt apart, centered.
        let padding: (CGFloat?, CGFloat?) = (6, showsToggles ? 72 : 6)
        if field.paddingOverride != padding { field.paddingOverride = padding }
        for (i, toggle) in [matchCase, wholeWord, regex].enumerated() {
            toggle.isHidden = !showsToggles
            toggle.frame = NSRect(x: x + fieldWidth - 4 - 62 + CGFloat(i) * 21, y: y + 4, width: 20, height: 20)
        }
        let countX = x + fieldWidth + Self.gap
        count.frame = NSRect(x: countX, y: y + 4, width: countWidth, height: 20)
        let navX = countX + countWidth + Self.gap
        previous.frame = NSRect(x: navX, y: y + 2, width: 24, height: 24)
        next.frame = NSRect(x: navX + 24, y: y + 2, width: 24, height: 24)
        // `top: 0; right: 0; transform: translate(50%, -50%)` on the padding box's corner.
        close.frame = NSRect(x: box.maxX - 1 - 10, y: box.minY + 1 - 10, width: 20, height: 20)
        close.isHidden = redesign
        ghostClose.isHidden = !redesign
        ghostClose.frame = NSRect(x: navX + 48 + 2, y: y + 2, width: 24, height: 24)
        for v in [previous, next] { v.isHidden = redesign }
        for v in [ghostPrevious, ghostNext] { v.isHidden = !redesign }
        if redesign { layoutRedesign(box) } else { count.alignment = .left }
    }

    /// The thread find bar's row (ThreadFindBarView): buttons from the right edge, the count left of them, the field
    /// with the case, word and regex toggles at its end filling the rest.
    private func layoutRedesign(_ box: CGRect) {
        var x = box.maxX - 5
        let y = box.minY + (box.height - 24) / 2
        for button in [ghostClose, ghostNext, ghostPrevious] {
            x -= 24; button.frame = NSRect(x: x, y: y, width: 24, height: 24); x -= 2
        }
        x -= countWidth
        count.alignment = .center
        count.frame = NSRect(x: x, y: box.minY + (box.height - 20) / 2, width: countWidth, height: 20)
        let fieldFrame = NSRect(x: box.minX + 1, y: box.minY + (box.height - 28) / 2, width: max(0, x - box.minX - 1), height: 28)
        field.frame = fieldFrame
        let padding: (CGFloat?, CGFloat?) = (11, showsToggles ? 70 : 6)
        if field.paddingOverride != padding { field.paddingOverride = padding }
        for (i, toggle) in [matchCase, wholeWord, regex].enumerated() {
            toggle.frame = NSRect(x: fieldFrame.maxX - 64 + CGFloat(i) * 21, y: box.minY + (box.height - 20) / 2, width: 20, height: 20)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // Redesign's close sits inside the box, so the box's width changes with the theme.
        needsLayout = true; superview?.needsLayout = true
    }

    override func updateLayer() {
        let fg = Themed.color(\.popoverForeground), bg = Themed.color(\.popover)
        let dark = effectiveAppearance.isDark
        if ThemeRuntime.isDither(dark: dark) {
            // Redesign: a floating surface (redesign-system.md, Surfaces), an inset card for the field, the accent
            // rim while it has the keyboard.
            var style = BoxStyle()
            style.radius = RedesignTokens.Radius.card
            // The field sits straight on the bar, as in the thread find bar; the bar's rim takes the accent while typing.
            style.fill = bg
            style.border = field.state.focused ? Themed.color(\.primary, Double(RedesignTokens.Surface.focusRim)) : RedesignTokens.Surface.rim(dark: dark)
            style.shadows = [RedesignTokens.Shadow.floating.box]
            box.boxStyle = style
            fieldBox.boxStyle = BoxStyle()
            syncCount()
            count.color = count.text == "0/0" ? Themed.color(\.destructive) : Themed.color(\.mutedForeground)
            return
        }
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
