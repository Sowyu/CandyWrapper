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
        resolvePreview()
    }

    func resolvePreview(threadTitle: (String) -> String? = { _ in nil }) -> (user: String?, assistant: String?) {
        func compact(_ text: String?) -> String? {
            let c = text?.split(whereSeparator: \.isWhitespace).joined(separator: " ") ?? ""
            return c.isEmpty ? nil : c
        }
        let answer = assistantText.map { MarkdownDocument(parsing: String($0.prefix(1_500)), preservesLineBreaks: false).blocks.map { Self.text($0, threadTitle: threadTitle) }.joined(separator: " ") }
        return (compact(userText), compact(answer))
    }

    /// `markdownNodeText` (:60-86): inline content joins as is, blocks with a space; images give their alt.
    static func text(_ block: MarkdownBlock, threadTitle: (String) -> String? = { _ in nil }) -> String {
        func text(_ block: MarkdownBlock) -> String { Self.text(block, threadTitle: threadTitle) }
        func runs(_ r: [InlineRun]) -> String { r.map { $0.threadLinkText(title: threadTitle) }.joined() }
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
    public var threadTitle: ((String) -> String?)?
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
    private func updateGutter() { HoverReveal.fade(self, to: persistentGutter || hovered != nil ? 1 : 0) }
    private func snapAlpha() { alphaValue = persistentGutter || hovered != nil ? 1 : 0 }

    public override var needsDisplay: Bool { didSet { if needsDisplay { ticks.needsDisplay = true } } }

    // MARK: Redesign

    /// Redesign (after Capy's chat minimap, which is T3's, with a preview card): one tick per turn, all the same size
    /// and evenly spaced (the user, 2026-10-22: "keep that bar the same"), the viewport as a soft band, on the
    /// composer's frosted pill surface so it reads over any art (the user, 2026-10-29: the faded see-through column
    /// "looks buns"). The ticks draw in their own view, above the surface.
    private var dither: Bool { ThemeRuntime.isDither(dark: effectiveAppearance.isDark) }
    /// Room for the surface and the band around the ticks. TimelineView outsets the frame by it.
    public var padding: CGFloat { dither ? 8 : 0 }
    private let surface = DitherPillSurface()
    private lazy var ticks = MinimapTicksView(rail: self)
    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        superview?.needsLayout = true
        needsLayout = true
    }
    /// Where turn `i`'s tick sits, inside the padding, on whole device pixels so the gaps come out even.
    fileprivate func tickY(_ i: Int) -> CGFloat {
        let scale = window?.backingScaleFactor ?? 2
        let y = padding + CGFloat(i) / CGFloat(max(1, items.count - 1)) * max(0, bounds.height - 2 * padding - 2)
        return (y * scale).rounded() / scale
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
        surface.radius = DitherChrome.cardRadius
        addSubview(surface); addSubview(ticks)
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
        surface.isHidden = !dither
        ticks.isHidden = !dither
        surface.frame = bounds
        ticks.frame = bounds
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
        let content = ThreadMinimapPreviewView(item: items[hovered], threadTitle: threadTitle ?? { _ in nil })
        let popover: PopupContent = dither ? DitherMinimapPreviewCard(content: content) : PopoverView(content: content, padding: .compact, width: .md)
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
        guard !dither, let ctx = NSGraphicsContext.current?.cgContext else { return }
        // The strip redraws whenever the current turn changes while scrolling. With 2,500 turns, a themed color and an
        // NSBezierPath per mark took 18% of the main thread in a long scroll; resolve the three colors once and fill
        // each mark straight into the context, in the same order, so overlapping marks blend as before.
        let current = Themed.color(\.foreground, ThreadDesign.uses3814(dark: effectiveAppearance.isDark) ? 0.55 : 0.9).cgColor
        let near = Themed.color(\.mutedForeground, ThreadDesign.uses3814(dark: effectiveAppearance.isDark) ? 0.6 : 0.75).cgColor
        let base = Themed.color(\.mutedForeground, ThreadDesign.uses3814(dark: effectiveAppearance.isDark) ? 0.25 : 0.35).cgColor
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

    /// Redesign's ticks over the surface: the band over the turns on screen, then one tick per turn, centred in the
    /// column. Four colors resolved once and plain rect fills, so a 2,500-turn redraw stays as cheap as the stock strip.
    fileprivate func drawDither(_ ctx: CGContext, _ dirtyRect: NSRect) {
        let band = Themed.color(\.foreground, 0.08).cgColor
        let bright = Themed.color(\.foreground, 0.9).cgColor
        let quiet = Themed.color(\.mutedForeground, 0.5).cgColor
        let accent = Themed.color(\.primary).cgColor
        let shown = inView.isEmpty ? currentIndex.map { IndexSet(integer: $0) } ?? IndexSet() : inView
        if let first = shown.first, let last = shown.last {
            let top = tickY(first) - 4, rect = CGRect(x: padding - 4, y: top, width: bounds.width - 2 * padding + 8, height: tickY(last) + 6 - top)
            let r = min(5, rect.height / 2)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil))
            ctx.setFillColor(band); ctx.fillPath()
        }
        // Every tick has the same size; the turns on screen draw brighter and the hovered one in the accent. Ticks closer
        // than 5pt thin to a hairline, so a long thread reads as evenly spaced marks instead of a solid bar.
        let width = min(Self.tickWidth, max(0, bounds.width - 2 * padding))
        let pitch = items.count > 1 ? (bounds.height - 2 * padding - 2) / CGFloat(items.count - 1) : .infinity
        let height: CGFloat = pitch < 5 ? 1 : 2
        let x = ((bounds.width - width) / 2).rounded()
        for i in items.indices {
            let rect = CGRect(x: x, y: tickY(i), width: width, height: height)
            guard rect.intersects(dirtyRect) else { continue }
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: height / 2, cornerHeight: height / 2, transform: nil))
            ctx.setFillColor(hovered == i ? accent : inView.contains(i) ? bright : quiet)
            ctx.fillPath()
        }
    }
}

/// Redesign's ticks, drawn above the rail's surface. Lets clicks through to the rail.
private final class MinimapTicksView: NSView {
    private unowned let rail: ThreadMinimapView
    init(rail: ThreadMinimapView) { self.rail = rail; super.init(frame: .zero) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { rail.isFlipped }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        rail.drawDither(ctx, dirtyRect)
    }
}

/// Redesign's preview card: the composer's pill surface, so the text sits on frosted glass, or an opaque card under
/// Reduce Transparency, instead of the thin popover fill over the art.
private final class DitherMinimapPreviewCard: DSView, PopupContent {
    private let surface = DitherPillSurface()
    private let content: NSView
    private static let inset = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
    init(content: NSView) {
        self.content = content
        super.init(frame: .zero)
        layer?.masksToBounds = false
        surface.radius = DitherChrome.cardRadius
        addSubview(surface); addSubview(content)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    var popupSize: CGSize {
        let i = Self.inset
        return CGSize(width: 320, height: content.intrinsicContentSize.height + i.top + i.bottom)
    }
    override var intrinsicContentSize: NSSize { popupSize }
    var frostRadius: CGFloat { DitherChrome.cardRadius }
    override func layout() {
        super.layout()
        surface.frame = bounds
        let i = Self.inset
        content.frame = NSRect(x: i.left, y: i.top, width: bounds.width - i.left - i.right, height: bounds.height - i.top - i.bottom)
    }
}

/// MessagesTimeline.tsx:1907-1931. The preview is built only while a strip is hovered.
private final class ThreadMinimapPreviewView: DSView {
    private let user: LabelView
    private let assistant: TextBlockView
    init(item: ThreadMinimapItem, threadTitle: (String) -> String?) {
        let texts = item.resolvePreview(threadTitle: threadTitle)
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
