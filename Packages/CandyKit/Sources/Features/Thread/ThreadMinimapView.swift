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
                // The attachment-only prompt is hidden in the thread, so the minimap shows nothing for it (timelineMinimapItems.ts at 4928).
                let text = UserMessagePresentation.isAttachmentOnlyBootstrapPrompt(message.text) ? "" : message.text
                result.append(Self(id: row.id, rowIndex: index, userText: text))
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
        func plain(_ markdown: String) -> String {
            MarkdownDocument(parsing: String(markdown.prefix(1_500)), preservesLineBreaks: false).blocks.map { Self.text($0, threadTitle: threadTitle) }.joined(separator: " ")
        }
        // A prompt's citations and context links read as their text before parsing, which would turn a citation
        // into "Assistant quote" (`markdownMinimapPreview`, timelineMinimapItems.ts:101-125 at 4928, #38250).
        let prompt = plain(ComposerInlineTokens.citationsToPlainText(ComposerInlineTokens.contextLabels(userText)))
        return (compact(prompt), compact(assistantText.map { plain($0) }))
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

/// TimelineMinimap.tsx (T3 4928). The strip redraws only after a scroll, content or hover change. Every theme draws
/// T3's default strip, Redesign included (the user, 2026-10-29).
public final class ThreadMinimapView: DSView, HoverSyncPointerClient {
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
    public var currentIndex: Int? { didSet { if currentIndex != oldValue { updateNavigation() } } }
    /// The timeline sits at its very bottom, so there is no next turn to go to.
    public var atEnd = false { didSet { if atEnd != oldValue { updateNavigation() } } }
    /// Strips whose turn is on screen draw bright (`data-in-view`, MessagesTimeline.tsx:1219-1234, 1890-1902).
    public var inView = IndexSet() { didSet { if inView != oldValue { needsDisplay = true } } }
    public var persistentGutter = true { didSet { if persistentGutter != oldValue { needsDisplay = true; snapAlpha() } } }
    /// Without a persistent gutter the strip fades in while hovered (`opacity-0 transition-opacity duration-150
    /// hover:opacity-100`, TimelineMinimap.tsx:118-123).
    private func updateGutter() { HoverReveal.fade(self, to: persistentGutter || hovered != nil ? 1 : 0) }
    private func snapAlpha() { alphaValue = persistentGutter || hovered != nil ? 1 : 0 }
    /// Where turn `i`'s strip sits. T3 centres each strip on `top: i / (n - 1)` of the rail (`-translate-y-1/2`); the
    /// strip stays inside the bounds here, so its centre is 1pt in from each end.
    private func tickY(_ i: Int) -> CGFloat { CGFloat(i) / CGFloat(max(1, items.count - 1)) * max(0, bounds.height - 2) }
    /// Each arrow fades in under its own pointer, not the strip's (`hover:opacity-100` on the arrow, :303-307).
    private var hoveredArrow: ButtonView? { didSet { if hoveredArrow !== oldValue { updateNavigation() } } }
    /// `size="icon-micro" variant="ghost-muted"` with a `size-4 text-foreground/90` chevron (TimelineMinimap.tsx:296-308 at 4928).
    private let previous = ButtonView(icon: .chevronUp, variant: .ghostMuted, size: .iconMicro)
    private let next = ButtonView(icon: .chevronDown, variant: .ghostMuted, size: .iconMicro)
    private weak var previewPopup: OpenPopup?
    public override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(previous); addSubview(next)
        previous.iconColor = Themed.color(\.foreground, 0.9); next.iconColor = Themed.color(\.foreground, 0.9)
        previous.setTooltip("Previous turn"); next.setTooltip("Next turn")
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
        next.isEnabled = !atEnd && (currentIndex ?? 0) < items.count - 1
        HoverReveal.fade([previous], visible: hoveredArrow === previous)
        HoverReveal.fade([next], visible: hoveredArrow === next)
    }
    public override func layout() {
        super.layout()
        // `left-1 -translate-x-1/2`, 6pt past each end (`bottom-[calc(100%+6px)]`, `top-[calc(100%+6px)]`, :287-291).
        previous.frame = NSRect(x: -6, y: -26, width: 20, height: 20)
        next.frame = NSRect(x: -6, y: bounds.height + 6, width: 20, height: 20)
    }
    public override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        for button in [previous, next] where button.alphaValue > 0 && button.frame.contains(local) { return button }
        return super.hitTest(point)
    }
    /// The card (TimelineMinimap.tsx:249-275): `left-8`, 32pt right of the strips, `w-80 p-3 rounded-xl dropdown-glass
    /// shadow-xl shadow-black/25`, its middle on the hovered strip, or its top on the first and its bottom on the last
    /// (`translateY(0% | -50% | -100%)`). The anchor is the strip's own centre, so the card sits on the strip drawn.
    private func showPreview() {
        if let old = previewPopup { previewPopup = nil; popupHost?.close(old, returnFocus: false) }
        guard let hovered, items.indices.contains(hovered), let host = popupHost else { return }
        let content = ThreadMinimapPreviewView(item: items[hovered], threadTitle: threadTitle ?? { _ in nil })
        let popover = PopoverView(content: content, padding: .card, width: .md, beforeLine: false, surface: .tooltipGlass, radius: 12)
        // Centered on its strip at the ends too, since the rail leaves room above and below (`-translate-y-1/2`,
        // TimelineMinimap.tsx at 4928, #32151).
        let align: PopupPlacement.Align = .center
        previewPopup = host.open(popover, trigger: self, anchorRect: NSRect(x: 24, y: tickY(hovered) + 1, width: 1, height: 0),
            placement: PopupPlacement(side: .right, align: align, sideOffset: 8), pressesTrigger: false, returnsFocus: false, passive: true)
        // A card closed from outside takes the fisheye with it, so the two never disagree.
        previewPopup?.onClose = { [weak self, weak popup = previewPopup] in
            guard let self, let popup, self.previewPopup === popup else { return }
            self.previewPopup = nil
            self.hovered = nil
        }
    }
    public override func viewDidMoveToWindow() {
        if window == nil, let previewPopup { previewPopup.content.popupHost?.close(previewPopup, returnFocus: false) }
        super.viewDidMoveToWindow()
        if window != nil { snapAlpha() }
    }
    public var onSelect: ((String) -> Void)?
    /// The hovered turn. The fisheye and the card both follow it: setting it opens or closes the card, and a card
    /// closed from outside (a click anywhere, Escape, another hover card) clears it.
    private var hovered: Int? { didSet {
        guard hovered != oldValue else { return }
        if hovered != nil { Haptics.tap(.alignment) } // a detent per turn, like a dial
        setTooltip(nil); needsDisplay = true; updateGutter(); showPreview()
    } }
    public override var wantsUpdateLayer: Bool { false }
    public override var acceptsFirstResponder: Bool { true }
    /// The strip's button, the only place that hovers a turn: the frame is T3's hit strip (`left-3`, at most 40pt,
    /// `resolveTimelineMinimapHitStripWidth`, MessagesTimeline.logic.ts:482-497 at 4928) and `before:-inset-y-1` adds
    /// 4pt above and below (TimelineMinimap.tsx:153). The card is display-only (`pointer-events-none`, :229), so a
    /// pointer on the card or anywhere over the messages has left the strip and the card closes.
    private var stripRect: NSRect { bounds.insetBy(dx: 0, dy: -4) }
    /// The strip and its arrows, which fade in under their own pointer.
    private var hoverRegion: NSRect { bounds.insetBy(dx: -8, dy: -28) }
    /// The arrows sit outside the strip's bounds, and AppKit drops the exit of an area that reaches outside its view
    /// when it is rebuilt under a moving pointer or its window stops being key. HoverSync delivers enter and exit from
    /// the pointer position after every move, geometry, key and app change, but only for areas inside their view.
    /// So the region lives on this sibling view, sized to it, and HoverSync owns the rail's hover.
    private let hoverZone = MinimapHoverZone()
    private func layoutHoverZone() {
        guard let superview, hoverZone.superview === superview else { return }
        let zone = convert(hoverRegion, to: superview).intersection(superview.bounds)
        if hoverZone.frame != zone { hoverZone.frame = zone }
    }
    public override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        hoverZone.removeFromSuperview()
        if let superview {
            if hoverZone.trackingAreas.isEmpty {
                hoverZone.addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect], owner: self))
            }
            superview.addSubview(hoverZone, positioned: .below, relativeTo: self)
            layoutHoverZone()
        } else {
            hovered = nil
        }
    }
    public override func setFrameOrigin(_ newOrigin: NSPoint) { super.setFrameOrigin(newOrigin); layoutHoverZone() }
    public override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); layoutHoverZone() }
    public override func viewDidHide() { super.viewDidHide(); hoverZone.isHidden = isHidden; hovered = nil; hoveredArrow = nil }
    public override func viewDidUnhide() { super.viewDidUnhide(); hoverZone.isHidden = isHidden }
    private func index(atY y: CGFloat) -> Int? {
        guard !items.isEmpty else { return nil }
        return max(0, min(items.count - 1, Int((y / max(1, bounds.height) * CGFloat(items.count - 1)).rounded())))
    }
    private func index(_ event: NSEvent) -> Int? { index(atY: convert(event.locationInWindow, from: nil).y) }
    /// The one place the pointer sets the hover: from where the pointer is now, not where an event said it was. Off
    /// the strip, on an arrow, the card or the messages, nothing is hovered (`onMouseLeave`, TimelineMinimap.tsx:185).
    private func trackPointer() {
        guard let window else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        hoveredArrow = [previous, next].first { $0.frame.contains(point) }
        hovered = stripRect.contains(point) ? index(atY: point.y) : nil
    }
    private var pointerInside = false
    public override func mouseEntered(with event: NSEvent) { pointerInside = true; trackPointer() }
    public func hoverPointerMoved() { if pointerInside { trackPointer() } }
    /// `onMouseLeave={() => setActiveIndex(null)}` (TimelineMinimap.tsx:185).
    public override func mouseExited(with event: NSEvent) { pointerInside = false; hovered = nil; hoveredArrow = nil }
    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if let i = index(event) { hovered = i; onSelect?(items[i].id) }
    }
    /// `onBlur={() => setActiveIndex(null)}` (TimelineMinimap.tsx:155): the keyboard's turn goes with the focus.
    public override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned, !pointerInside { hovered = nil }
        return resigned
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
        // The strip redraws whenever the current turn changes while scrolling. With 2,500 turns, a themed color and an
        // NSBezierPath per mark took 18% of the main thread in a long scroll; resolve the colors once and fill each
        // mark straight into the context, in the same order, so overlapping marks blend as before.
        // T3's strip (TimelineMinimap.tsx:194-214 at 4928): `bg-muted-foreground/25`, `/60` on the hovered strip, and
        // `after:bg-foreground/55` over it while its turn is on screen. 4928 has no guide line under the strips (#35577).
        // Over Redesign's picture each state is one opaque color with T3's contrast ratios instead.
        let backdrop = Self.backdropColors(dark: effectiveAppearance.isDark)
        let current = (backdrop?[2] ?? Themed.color(\.foreground, 0.55)).cgColor
        let near = (backdrop?[1] ?? Themed.color(\.mutedForeground, 0.6)).cgColor
        let base = (backdrop?[0] ?? Themed.color(\.mutedForeground, 0.25)).cgColor
        let nearCurrent = backdrop?[3].cgColor
        for i in items.indices {
            let distance = hovered.map { abs(i - $0) }
            let width: CGFloat = distance == 0 ? 24 : distance == 1 ? 16 : distance == 2 ? 10 : 8
            let rect = CGRect(x: 0, y: tickY(i), width: width, height: 2)
            guard rect.intersects(dirtyRect) else { continue }
            let path = CGPath(roundedRect: rect, cornerWidth: 1, cornerHeight: 1, transform: nil)
            if let nearCurrent, inView.contains(i) {
                ctx.setFillColor(distance == 0 ? nearCurrent : current)
                ctx.addPath(path)
                ctx.fillPath()
                continue
            }
            ctx.setFillColor(distance == 0 ? near : base)
            ctx.addPath(path)
            ctx.fillPath()
            if backdrop == nil, inView.contains(i) {
                ctx.setFillColor(current)
                ctx.addPath(path)
                ctx.fillPath()
            }
        }
    }
}

extension ThreadMinimapView {
    /// T3's four strip states: resting, hovered, on screen, and hovered on screen. The first three keep T3's ratios;
    /// the hovered on-screen strip is the brightest and may stop at white.
    static let strips: [[BackdropMarks.Layer]] = [
        [.init(\.mutedForeground, 0.25)], [.init(\.mutedForeground, 0.6)],
        [.init(\.mutedForeground, 0.25), .init(\.foreground, 0.55)], [.init(\.mutedForeground, 0.6), .init(\.foreground, 0.55)],
    ]
    static func backdropColors(dark: Bool) -> [NSColor]? { BackdropMarks.colors(strips, keep: 3, dark: dark) }
}

/// Holds the rail's hover area where HoverSync can find it. It draws nothing and lets every click through.
private final class MinimapHoverZone: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// TimelineMinimap.tsx:249-275. The preview is built only while a strip is hovered.
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
