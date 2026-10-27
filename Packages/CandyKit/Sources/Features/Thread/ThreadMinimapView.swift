import AppKit
import DesignSystem
import T3Store

/// timelineMinimapItems.ts:15-77. Keep the source text until a preview is requested.
public struct ThreadMinimapItem: Equatable, Sendable {
    public var id: String
    public var rowIndex: Int
    public var userText: String
    public var assistantText: String?
    var assistantRowIndex: Int?
    public static func derive(_ rows: [TimelineRow]) -> [Self] {
        var result: [Self] = []
        for (index, row) in rows.enumerated() {
            guard case .message(let message, _, _, _, _, _) = row.kind else { continue }
            if message.role == .user {
                result.append(Self(id: row.id, rowIndex: index, userText: message.text))
            } else if message.role == .assistant, !result.isEmpty {
                result[result.count - 1].assistantText = message.text
                result[result.count - 1].assistantRowIndex = index
            }
        }
        return result
    }
    public var preview: String {
        let texts = resolvedPreview
        return [texts.user, texts.assistant].compactMap { $0 }.joined(separator: "\n\n")
    }

    /// `resolveTimelineMinimapPreview` (timelineMinimapItems.ts:94-110): whitespace compacted, and the answer
    /// read as plain text from its first 1,500 characters, so the tooltip never shows markdown source.
    // ponytail: inline HTML stays as its source text; strip tags like `markdownNodeText` (:67-79) if replies with HTML show it.
    var resolvedPreview: (user: String?, assistant: String?) {
        func compact(_ text: String?) -> String? {
            let c = text?.split(whereSeparator: \.isWhitespace).joined(separator: " ") ?? ""
            return c.isEmpty ? nil : c
        }
        let answer = assistantText.map { MarkdownDocument(parsing: String($0.prefix(1_500)), preservesLineBreaks: false).blocks.map(Self.text).joined(separator: " ") }
        return (compact(userText), compact(answer))
    }

    /// `markdownNodeText` (:60-86): inline content joins as is, blocks with a space; images give their alt.
    static func text(_ block: MarkdownBlock) -> String {
        func runs(_ r: [InlineRun]) -> String { r.map(\.text).joined() }
        switch block {
        case .paragraph(let r), .heading(_, let r): return runs(r)
        case .list(let list): return list.items.map { $0.blocks.map(text).joined(separator: " ") }.joined(separator: " ")
        case .blockquote(let blocks), .alert(_, let blocks): return blocks.map(text).joined(separator: " ")
        case .code(_, _, let code): return code
        case .table(let t): return ([t.header] + t.rows).map { $0.map(runs).joined(separator: " ") }.joined(separator: " ")
        case .rule: return ""
        case .image(let alt, _): return alt
        case .math(let math): return math.copySource
        }
    }
}

/// MessagesTimeline.tsx:1785-1934. The strip redraws only after a scroll, content or hover change.
public final class ThreadMinimapView: DSView {
    public var items: [ThreadMinimapItem] = [] { didSet {
        guard !updatingPreview else { return }
        if let hovered, !items.indices.contains(hovered) { self.hovered = nil }
        if items != oldValue { needsDisplay = true }
    } }
    private var updatingPreview = false
    /// Wheel over the strip scrolls the chat (`forwardWheelToTimeline`, T3 3105 c9181d81a).
    var onWheel: ((NSEvent) -> Void)?
    public override func scrollWheel(with event: NSEvent) {
        if let onWheel { onWheel(event) } else { super.scrollWheel(with: event) }
    }
    /// Text does not affect the strip geometry. Avoid comparing every item on each streamed token.
    func updatePreview(at index: Int, text: String, assistant: Bool) {
        guard items.indices.contains(index) else { return }
        updatingPreview = true
        if assistant { items[index].assistantText = text } else { items[index].userText = text }
        updatingPreview = false
        if hovered == index { showPreview() }
    }
    /// The turn at the reader's position, for the previous and next buttons (`resolveTimelineMinimapCurrentIndex`).
    public var currentIndex: Int? { didSet { if currentIndex != oldValue { updateNavigation(); if dither, inView.isEmpty { needsDisplay = true } } } }
    /// Strips whose turn is on screen draw bright (`data-in-view`, MessagesTimeline.tsx:1219-1234, 1890-1902).
    public var inView = IndexSet() { didSet { if inView != oldValue { needsDisplay = true } } }
    public var persistentGutter = true { didSet { if persistentGutter != oldValue { needsDisplay = true; snapAlpha() } } }
    /// Without a persistent gutter the strip fades in while hovered (`opacity-0 transition-opacity duration-150
    /// hover:opacity-100`, MessagesTimeline.tsx:1788-1792).
    private func updateGutter() {
        guard dither else { HoverReveal.fade(self, to: persistentGutter || hovered != nil ? 1 : 0); return }
        fadeOpacity(to: hovered != nil ? 1 : restingAlpha, hold: 0)
    }
    private func snapAlpha() {
        layer?.removeAnimation(forKey: Self.fadeKey)
        alphaValue = hovered != nil ? 1 : dither ? restingAlpha : persistentGutter ? 1 : 0
    }

    // MARK: Redesign

    /// Redesign (after Capy's chat minimap, which is T3's, with a preview card): one tick per turn, all the same size
    /// and evenly spaced (the user, 2026-10-22: "keep that bar the same"), the viewport as a soft band, and a tinted
    /// backing so it reads over bright and dark art. It rests almost faded and comes back while scrolling or hovered.
    private var dither: Bool { ThemeRuntime.isDither(dark: effectiveAppearance.isDark) }
    /// Room for the backing and the band around the ticks. TimelineView outsets the frame by it.
    public var padding: CGFloat { dither ? 8 : 0 }
    /// Capy's idle scrollbar sits at 30%; the column keeps just enough to show where it is.
    private var restingAlpha: CGFloat { persistentGutter ? 0.22 : 0 }
    private static let fadeKey = "minimapFade"
    private var lastReveal: CFTimeInterval = 0
    /// Brings the column up for a moment after the reader scrolls, then lets it settle. One Core Animation
    /// keyframe per 100 ms of scrolling, and nothing once it has settled.
    public func revealForScroll() {
        guard dither, persistentGutter, hovered == nil, !isHidden, window != nil else { return }
        let now = CACurrentMediaTime()
        guard now - lastReveal > 0.1 else { return }
        lastReveal = now
        fadeOpacity(to: restingAlpha, hold: 0.9)
    }
    /// Fades from what is on screen now to `target`; with `hold`, rises to full first and stays there `hold` seconds.
    private func fadeOpacity(to target: CGFloat, hold: TimeInterval) {
        guard let layer else { alphaValue = target; return }
        let from = CGFloat(layer.presentation()?.opacity ?? layer.opacity)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        alphaValue = target
        CATransaction.commit()
        guard window != nil, from != target || hold > 0 else { layer.removeAnimation(forKey: Self.fadeKey); return }
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        let rise = 0.15, fall = 0.4
        if hold > 0 {
            let total = rise + hold + fall
            fade.values = [from, 1, 1, target]
            fade.keyTimes = [0, rise / total, (rise + hold) / total, 1].map { NSNumber(value: $0) }
            fade.duration = total
        } else {
            fade.values = [from, target]
            fade.duration = target > from ? rise : 0.25
        }
        fade.timingFunction = Motion.easeInOut
        if Motion.reduced { fade.calculationMode = .discrete }
        layer.add(fade, forKey: Self.fadeKey)
    }
    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        snapAlpha()
        superview?.needsLayout = true
    }
    /// Where turn `i`'s tick sits, inside the padding.
    private func tickY(_ i: Int) -> CGFloat {
        padding + CGFloat(i) / CGFloat(max(1, items.count - 1)) * max(0, bounds.height - 2 * padding - 2)
    }
    /// Each arrow fades in under its own pointer, not the strip's (`hover:opacity-100` on the arrow, :1969-1975).
    private var hoveredArrow: ButtonView? { didSet { if hoveredArrow !== oldValue { updateNavigation() } } }
    private func arrow(_ event: NSEvent) -> ButtonView? {
        let p = convert(event.locationInWindow, from: nil)
        return [previous, next].first { $0.frame.contains(p) }
    }
    private let previous = ButtonView(icon: .chevronUp, variant: .ghost, size: .iconXs)
    private let next = ButtonView(icon: .chevronDown, variant: .ghost, size: .iconXs)
    private weak var previewPopup: OpenPopup?
    public override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(previous); addSubview(next)
        previous.toolTip = "Previous turn"; next.toolTip = "Next turn"
        previous.setAccessibilityLabel("Previous turn"); next.setAccessibilityLabel("Next turn")
        previous.action = { [weak self] in self?.navigate(-1) }
        next.action = { [weak self] in self?.navigate(1) }
        updateNavigation()
    }
    private func navigate(_ delta: Int) {
        let index = (currentIndex ?? 0) + delta
        guard items.indices.contains(index) else { return }
        onSelect?(items[index].id)
    }
    private func updateNavigation() {
        previous.isEnabled = (currentIndex ?? 0) > 0
        next.isEnabled = (currentIndex ?? 0) < items.count - 1
        HoverReveal.fade([previous], visible: hoveredArrow === previous)
        HoverReveal.fade([next], visible: hoveredArrow === next)
    }
    public override func layout() {
        super.layout()
        previous.frame = NSRect(x: padding - 8, y: padding - 26, width: 24, height: 24)
        next.frame = NSRect(x: padding - 8, y: bounds.height - padding + 2, width: 24, height: 24)
    }
    public override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        for button in [previous, next] where button.alphaValue > 0 && button.frame.contains(local) { return button }
        return super.hitTest(point)
    }
    private func showPreview() {
        if let previewPopup { popupHost?.close(previewPopup, returnFocus: false) }
        guard let hovered, items.indices.contains(hovered), let host = popupHost else { return }
        let content = ThreadMinimapPreviewView(item: items[hovered])
        let popover = PopoverView(content: content, padding: .compact, width: .md)
        let y = dither ? tickY(hovered) : CGFloat(hovered) / CGFloat(max(1, items.count - 1)) * bounds.height
        previewPopup = host.open(popover, trigger: self, anchorRect: NSRect(x: 24 + padding, y: y, width: 1, height: 2),
            placement: PopupPlacement(side: .right, align: .center, sideOffset: 8), pressesTrigger: false, returnsFocus: false, passive: true)
    }
    public override func viewDidMoveToWindow() {
        if window == nil, let previewPopup { previewPopup.content.popupHost?.close(previewPopup, returnFocus: false) }
        super.viewDidMoveToWindow()
        if window != nil { snapAlpha() }
    }
    public var onSelect: ((String) -> Void)?
    private var hovered: Int? { didSet {
        guard hovered != oldValue else { return }
        toolTip = nil; needsDisplay = true; updateGutter(); showPreview()
    } }
    private var tracking: NSTrackingArea?
    public override var wantsUpdateLayer: Bool { false }
    public override var acceptsFirstResponder: Bool { true }
    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds.insetBy(dx: -8, dy: -28), options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited], owner: self)
        tracking = area; addTrackingArea(area)
    }
    private func index(_ event: NSEvent) -> Int? {
        guard !items.isEmpty else { return nil }
        let y = convert(event.locationInWindow, from: nil).y - padding
        return max(0, min(items.count - 1, Int((y / max(1, bounds.height - 2 * padding) * CGFloat(items.count - 1)).rounded())))
    }
    public override func mouseEntered(with event: NSEvent) { hovered = index(event); hoveredArrow = arrow(event) }
    public override func mouseMoved(with event: NSEvent) { hovered = index(event); hoveredArrow = arrow(event) }
    public override func mouseExited(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if !bounds.insetBy(dx: -8, dy: -28).contains(point) { hovered = nil; hoveredArrow = nil }
    }
    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if let i = index(event) { hovered = i; onSelect?(items[i].id) }
    }
    public override func keyDown(with event: NSEvent) {
        guard !items.isEmpty else { return }
        switch event.keyCode {
        case 125: hovered = min(items.count - 1, (hovered ?? currentIndex ?? -1) + 1)
        case 126: hovered = max(0, (hovered ?? currentIndex ?? 1) - 1)
        case 115: hovered = 0
        case 119: hovered = items.count - 1
        case 36, 49: onSelect?(items[min(items.count - 1, max(0, hovered ?? currentIndex ?? 0))].id)
        default: super.keyDown(with: event)
        }
    }
    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if dither { drawDither(ctx, dirtyRect); return }
        // The strip redraws whenever the current turn changes while scrolling. With 2,500 turns, a themed color and an
        // NSBezierPath per mark took 18% of the main thread in a long scroll; resolve the three colors once and fill
        // each mark straight into the context, in the same order, so overlapping marks blend as before.
        let current = Themed.color(\.foreground, 0.9).cgColor
        let near = Themed.color(\.mutedForeground, 0.75).cgColor
        let base = Themed.color(\.mutedForeground, 0.35).cgColor
        let span = max(0, bounds.height - 2), last = CGFloat(max(1, items.count - 1))
        for i in items.indices {
            let distance = hovered.map { abs(i - $0) }
            let width: CGFloat = distance == 0 ? 24 : distance == 1 ? 16 : distance == 2 ? 10 : 8
            let rect = CGRect(x: 0, y: CGFloat(i) / last * span, width: width, height: 2)
            guard rect.intersects(dirtyRect) else { continue }
            let path = CGPath(roundedRect: rect, cornerWidth: 1, cornerHeight: 1, transform: nil)
            ctx.setFillColor(distance == 0 ? near : base)
            ctx.addPath(path)
            ctx.fillPath()
            if inView.contains(i) {
                ctx.setFillColor(current)
                ctx.addPath(path)
                ctx.fillPath()
            }
        }
    }
}

extension ThreadMinimapView {
    static let tickWidth: CGFloat = 10

    /// Redesign's column: the backing, the band over the turns on screen, then one tick per turn. Three colors
    /// resolved once and plain rect fills, so a 2,500-turn redraw stays as cheap as the stock strip.
    fileprivate func drawDither(_ ctx: CGContext, _ dirtyRect: NSRect) {
        let backing = Themed.color(\.background, 0.55).cgColor
        let band = Themed.color(\.foreground, 0.1).cgColor
        let bright = Themed.color(\.foreground, 0.95).cgColor
        let quiet = Themed.color(\.mutedForeground, 0.55).cgColor
        ctx.addPath(CGPath(roundedRect: bounds, cornerWidth: DitherChrome.controlRadius, cornerHeight: DitherChrome.controlRadius, transform: nil))
        ctx.setFillColor(backing); ctx.fillPath()
        let shown = inView.isEmpty ? currentIndex.map { IndexSet(integer: $0) } ?? IndexSet() : inView
        if let first = shown.first, let last = shown.last {
            let top = tickY(first) - 4, rect = CGRect(x: padding - 4, y: top, width: bounds.width - 2 * padding + 8, height: tickY(last) + 6 - top)
            let r = min(5, rect.height / 2)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil))
            ctx.setFillColor(band); ctx.fillPath()
        }
        // Every tick has the same size; the hovered tick and the turns on screen only draw brighter.
        let width = min(Self.tickWidth, max(0, bounds.width - 2 * padding))
        for i in items.indices {
            let rect = CGRect(x: padding, y: tickY(i), width: width, height: 2)
            guard rect.intersects(dirtyRect) else { continue }
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 1, cornerHeight: 1, transform: nil))
            ctx.setFillColor(hovered == i || inView.contains(i) ? bright : quiet)
            ctx.fillPath()
        }
    }
}

/// MessagesTimeline.tsx:1907-1931. The preview is built only while a strip is hovered.
private final class ThreadMinimapPreviewView: DSView {
    private let user: LabelView
    private let assistant: TextBlockView
    init(item: ThreadMinimapItem) {
        let texts = item.resolvedPreview
        user = LabelView(texts.user ?? "", font: DSFont.ui(14, weight: .medium))
        user.lineHeight = 20
        assistant = TextBlockView(texts.assistant ?? "", font: DSFont.ui(14), lineHeight: 20, color: Themed.color(\.mutedForeground))
        assistant.maxLines = 3
        super.init(frame: .zero)
        addSubview(user); addSubview(assistant)
    }
    override var intrinsicContentSize: NSSize { NSSize(width: 294, height: 20 + (assistant.text.isEmpty ? 0 : 4 + assistant.height(forWidth: 294))) }
    override func layout() {
        super.layout(); user.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 20)
        assistant.frame = NSRect(x: 0, y: 24, width: bounds.width, height: max(0, bounds.height - 24))
    }
}
