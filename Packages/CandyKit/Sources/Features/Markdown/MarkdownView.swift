import AppKit
import DesignSystem

/// T3's `ChatMarkdown` for one message: all text, rules and boxes drawn into one layer, plus the
/// code block and table buttons as real controls. Height follows the width: `height(forWidth:)`
/// lays out once per width and caches the result until the document changes, so the virtualized
/// timeline can measure rows cheaply. Reuse a view for another message by setting `document`.
// ponytail: one backing layer per message; a very long message gets a large layer. Switch to tiled drawing if memory shows it.
public final class MarkdownView: DSView {
    public var document = MarkdownDocument(blocks: []) {
        didSet { if document != oldValue { unwrappedCode = []; invalidate() } }
    }

    /// Body text color; nil is T3's 80% foreground. Headings, links and code keep their own colors.
    public var bodyColor: NSColor? {
        didSet { if bodyColor != oldValue { invalidate() } }
    }

    /// Parses and shows `markdown`. User messages pass `preservesLineBreaks`.
    public func setMarkdown(_ markdown: String, preservesLineBreaks: Bool = false) {
        document = MarkdownDocument(parsing: markdown, preservesLineBreaks: preservesLineBreaks)
    }

    private var unwrappedCode: Set<Int> = []
    private var cache: [CGFloat: MarkdownLayout] = [:]
    private var buttons: [ButtonView] = []
    private var copiedResets: [Int: DispatchWorkItem] = [:]

    public override var wantsUpdateLayer: Bool { false }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.isOpaque = false
    }

    private func invalidate() {
        cache.removeAll()
        invalidateIntrinsicContentSize()
        needsLayout = true
        needsDisplay = true
    }

    public func layout(forWidth width: CGFloat) -> MarkdownLayout {
        if let hit = cache[width] { return hit }
        // ponytail: unbounded per-width cache, cleared on document change; cap it if live resizing measures many widths
        let made = MarkdownLayout(document: document, width: width, unwrappedCode: unwrappedCode, bodyColor: bodyColor)
        cache[width] = made
        return made
    }

    public func height(forWidth width: CGFloat) -> CGFloat {
        document.blocks.isEmpty ? 0 : layout(forWidth: width).height
    }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: bounds.width > 0 ? height(forWidth: bounds.width) : NSView.noIntrinsicMetric)
    }

    public override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { invalidateIntrinsicContentSize(); needsDisplay = true }
    }

    // MARK: Controls

    public override func layout() {
        super.layout()
        let controls = bounds.width > 0 ? layout(forWidth: bounds.width).controls : []
        while buttons.count < controls.count {
            let button = ButtonView(icon: .copy, variant: .ghostMuted, size: .iconXs)
            button.iconSize = 12
            addSubview(button)
            buttons.append(button)
        }
        for (i, button) in buttons.enumerated() {
            guard i < controls.count else { button.isHidden = true; continue }
            let control = controls[i]
            button.isHidden = false
            button.frame = control.frame
            if copiedResets[i] == nil, button.icon != control.icon { button.icon = control.icon }
            if button.variant != control.variant { button.variant = control.variant }
            switch control.action {
            case .copy(let text):
                button.setAccessibilityLabel("Copy")
                button.action = { [weak self] in self?.copy(text, button: i) }
            case .toggleWrap(let index):
                button.setAccessibilityLabel(unwrappedCode.contains(index) ? "Wrap lines" : "Disable line wrap")
                button.action = { [weak self] in self?.toggleWrap(index) }
            case .toggleTable:
                button.setAccessibilityLabel("Collapse table cells")
                // ponytail: cells never truncate yet, so the toggle has nothing to collapse; wire it with cell truncation
                button.action = nil
            }
        }
    }

    private func copy(_ text: String, button index: Int) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        // T3 swaps the icon to a check for 1.2s.
        buttons[index].icon = .check
        copiedResets[index]?.cancel()
        let reset = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.copiedResets[index] = nil
            self.needsLayout = true
        }
        copiedResets[index] = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: reset)
    }

    private func toggleWrap(_ index: Int) {
        if unwrappedCode.contains(index) { unwrappedCode.remove(index) } else { unwrappedCode.insert(index) }
        invalidate()
    }

    // MARK: Drawing

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, bounds.width > 0, !document.blocks.isEmpty else { return }
        ctx.setShouldSmoothFonts(true)
        ctx.setAllowsFontSmoothing(true)
        let dark = effectiveAppearance.isDark
        for item in layout(forWidth: bounds.width).items {
            switch item {
            case .text(let box, let origin):
                guard origin.y <= dirtyRect.maxY, origin.y + box.height >= dirtyRect.minY else { continue }
                box.draw(in: ctx, at: origin)
            case .box(let rect, let fill, let border, let radius):
                drawBox(rect, fill: fill, border: border, radius: radius, in: ctx)
            case .glyphs(let string, let point):
                let line = CTLineCreateWithAttributedString(string)
                let width = CTLineGetTypographicBounds(line, nil, nil, nil)
                ctx.saveGState()
                ctx.textMatrix = .identity
                ctx.translateBy(x: point.x - width, y: point.y)
                ctx.scaleBy(x: 1, y: -1)
                ctx.textPosition = .zero
                CTLineDraw(line, ctx)
                ctx.restoreGState()
            case .symbol(let kind, let rect, let color):
                ctx.setFillColor(color.cgColor(in: self))
                ctx.setStrokeColor(color.cgColor(in: self))
                switch kind {
                case 0: ctx.fillEllipse(in: rect)
                case 1: ctx.setLineWidth(1); ctx.strokeEllipse(in: rect)
                default: ctx.fill(rect)
                }
            case .checkbox(let rect, let checked):
                drawCheckbox(rect, checked: checked, dark: dark, in: ctx)
            case .icon(let name, let rect, let color):
                drawIcon(name, in: rect, color: color.cgColor(in: self), ctx: ctx)
            case .clip(let rect):
                ctx.saveGState()
                ctx.clip(to: rect)
            case .endClip:
                ctx.restoreGState()
            }
        }
    }

    /// CSS box: the border is drawn inside the rect, the fill inside the border.
    /// Blink snaps box edges to device pixels (`PixelSnappedIntRect`): each edge rounds on its own.
    // ponytail: 2x device pixels, like TextLine.baseline
    private func drawBox(_ unsnapped: CGRect, fill: NSColor?, border: NSColor?, radius: CGFloat, in ctx: CGContext) {
        func snap(_ v: CGFloat) -> CGFloat { (v * 2).rounded() / 2 }
        let x0 = snap(unsnapped.minX), y0 = snap(unsnapped.minY)
        let rect = CGRect(x: x0, y: y0, width: max(0.5, snap(unsnapped.maxX) - x0), height: max(0.5, snap(unsnapped.maxY) - y0))
        func path(_ r: CGRect, _ radius: CGFloat) -> CGPath {
            radius > 0 ? CGPath(roundedRect: r, cornerWidth: min(radius, r.width / 2), cornerHeight: min(radius, r.height / 2), transform: nil)
                       : CGPath(rect: r, transform: nil)
        }
        let inner = border == nil ? rect : rect.insetBy(dx: 1, dy: 1)
        if let fill {
            ctx.setFillColor(fill.cgColor(in: self))
            ctx.addPath(path(inner, max(0, radius - (border == nil ? 0 : 1))))
            ctx.fillPath()
        }
        if let border {
            ctx.setFillColor(border.cgColor(in: self))
            ctx.addPath(path(rect, radius))
            ctx.addPath(path(inner, max(0, radius - 1)))
            ctx.fillPath(using: .evenOdd)
        }
    }

    /// Chromium's disabled checkbox, sampled from the reference renders: 13px, 2px radius, 1px border;
    /// checked is a solid box with a check stroked at 16% of its size.
    private func drawCheckbox(_ rect: CGRect, checked: Bool, dark: Bool, in ctx: CGContext) {
        func gray(_ v: CGFloat) -> CGColor { CGColor(srgbRed: v / 255, green: v / 255, blue: v / 255, alpha: 1) }
        let outer = CGPath(roundedRect: rect, cornerWidth: 2, cornerHeight: 2, transform: nil)
        if checked {
            ctx.setFillColor(gray(dark ? 0x88 : 0xd9))
            ctx.addPath(outer)
            ctx.fillPath()
            let w = rect.width, h = rect.height
            ctx.move(to: CGPoint(x: rect.minX + w * 0.2, y: rect.minY + h * 0.5))
            ctx.addLine(to: CGPoint(x: rect.minX + w * 0.4, y: rect.minY + h * 0.7))
            ctx.addLine(to: CGPoint(x: rect.minX + w * 0.8, y: rect.minY + h * 0.3))
            ctx.setStrokeColor(gray(dark ? 0x4c : 0xf0))
            ctx.setLineWidth(h * 0.16)
            ctx.strokePath()
        } else {
            ctx.setFillColor(gray(dark ? 0x75 : 0xd9))
            ctx.addPath(outer)
            ctx.fillPath()
            ctx.setFillColor(gray(dark ? 0x4c : 0xf9))
            ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: 1, dy: 1), cornerWidth: 1, cornerHeight: 1, transform: nil))
            ctx.fillPath()
        }
    }

    /// A lucide icon: stroked paths scaled from the 24-unit view box, stroke width 2 units.
    private func drawIcon(_ name: IconName, in rect: CGRect, color: CGColor, ctx: CGContext) {
        let definition = name.definition
        let scale = rect.width / definition.viewBox.width
        ctx.saveGState()
        ctx.translateBy(x: rect.minX - definition.viewBox.x * scale, y: rect.minY - definition.viewBox.y * scale)
        ctx.scaleBy(x: scale, y: scale)
        ctx.setStrokeColor(color)
        ctx.setLineWidth(2)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for element in definition.elements {
            guard let path = try? element.cgPath() else { continue }
            ctx.addPath(path)
            ctx.strokePath()
        }
        ctx.restoreGState()
    }
}
