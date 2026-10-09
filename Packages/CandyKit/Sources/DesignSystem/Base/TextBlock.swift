import AppKit
import CoreText

/// Wrapped lines of single-style text at one width, laid out like a CSS block:
/// each line box is `lineHeight` tall and the glyph box sits centered in it (`TextLine.baseline`).
public struct TextBlockLayout {
    public let lines: [TextLine]
    /// Advance of each line without its trailing spaces, which hang past the edge as in CSS.
    public let widths: [CGFloat]
    public let lineHeight: CGFloat
    public var height: CGFloat { CGFloat(lines.count) * lineHeight }

    /// Breaks at Core Text's suggested opportunities (UAX 14, the same rules Chromium's ICU breaker
    /// uses for prose). `maxLines` > 0 clamps like `line-clamp`: the last line ends in an ellipsis.
    /// `balanced` copies `text-wrap: balance`: the narrowest width that keeps the line count.
    // ponytail: balance is a binary search on width, Chromium's balancer scores line lengths; revisit if a balanced heading wraps differently
    public init(_ string: NSAttributedString, width: CGFloat, lineHeight: CGFloat, maxLines: Int = 0, balanced: Bool = false) {
        self.lineHeight = lineHeight
        let typesetter = CTTypesetterCreateWithAttributedString(string)
        let length = string.length
        // Chromium compares widths in LayoutUnits (1/64 px); the epsilon keeps an exact fit on one line.
        func breaks(_ width: CGFloat) -> [CFRange] {
            var ranges: [CFRange] = [], start = 0
            while start < length {
                var count = CTTypesetterSuggestLineBreak(typesetter, start, Double(max(width, 1)) + 1.0 / 64)
                if count <= 0 { count = length - start }
                ranges.append(CFRange(location: start, length: count))
                start += count
            }
            return ranges
        }
        var ranges = breaks(width)
        if balanced, ranges.count > 1, ranges.count <= 6 {
            var lo: CGFloat = 0, hi = width
            while hi - lo > 0.5 {
                let mid = (lo + hi) / 2
                if breaks(mid).count > ranges.count { lo = mid } else { hi = mid }
            }
            ranges = breaks(hi)
        }
        var lines = ranges.map { TextLine(line: CTTypesetterCreateLine(typesetter, $0)) }
        if maxLines > 0, lines.count > maxLines {
            let start = ranges[maxLines - 1].location
            let rest = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: length - start))
            let attributes = string.attributes(at: 0, effectiveRange: nil)
            let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "\u{2026}", attributes: attributes))
            let last = CTLineCreateTruncatedLine(rest, Double(width), .end, ellipsis) ?? rest
            lines = Array(lines.prefix(maxLines - 1)) + [TextLine(line: last)]
        }
        self.lines = lines
        widths = lines.map { $0.width - CGFloat(CTLineGetTrailingWhitespaceWidth($0.line)) }
    }

    /// Draws into a flipped (top-left origin) context with the block's top-left at `origin`.
    public func draw(in ctx: CGContext, origin: CGPoint, width: CGFloat, alignment: NSTextAlignment) {
        ctx.saveGState()
        ctx.textMatrix = .identity
        for (i, line) in lines.enumerated() {
            let x: CGFloat
            switch alignment {
            case .center: x = (width - widths[i]) / 2
            case .right: x = width - widths[i]
            default: x = 0
            }
            let baseline = line.baseline(top: origin.y + CGFloat(i) * lineHeight, lineHeight: lineHeight)
            ctx.saveGState()
            ctx.translateBy(x: origin.x + x, y: baseline)
            ctx.scaleBy(x: 1, y: -1)
            ctx.textPosition = .zero
            CTLineDraw(line.line, ctx)
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }
}

/// Multi-line, word-wrapping text with CSS line boxes. Height follows the width:
/// `height(forWidth:)` measures, and the layout is cached per width until the text or font changes.
public final class TextBlockView: DSView {
    public var text: String = "" { didSet { if text != oldValue { invalidate() } } }
    public var font: NSFont = DSFont.ui(14) { didSet { invalidate() } }
    public var color: NSColor = ThemeColors.main.color(\.foreground) { didSet { needsDisplay = true } }
    /// CSS line-height in points. Defaults to the font's natural height.
    public var lineHeight: CGFloat? { didSet { invalidate() } }
    public var alignment: NSTextAlignment = .left { didSet { needsDisplay = true } }
    /// `line-clamp`; 0 means unlimited.
    public var maxLines = 0 { didSet { invalidate() } }
    /// `text-wrap: balance`.
    public var balanced = false { didSet { invalidate() } }

    public override var wantsUpdateLayer: Bool { false }

    public convenience init(_ text: String, font: NSFont = DSFont.ui(14), lineHeight: CGFloat? = nil, color: NSColor? = nil) {
        self.init(frame: .zero)
        self.text = text
        self.font = font
        self.lineHeight = lineHeight
        if let color { self.color = color }
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.isOpaque = false
    }

    private var cache: [CGFloat: TextBlockLayout] = [:]

    private func invalidate() {
        cache.removeAll()
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    public var resolvedLineHeight: CGFloat { lineHeight ?? ceil(font.ascender - font.descender + font.leading) }

    public func layout(forWidth width: CGFloat) -> TextBlockLayout {
        if let hit = cache[width] { return hit }
        // ponytail: unbounded per-width cache, cleared on any text change; cap it if a resize drag measures hundreds of widths
        // Color comes from the context at draw time, so one cached layout serves both themes.
        let attributes: [NSAttributedString.Key: Any] = [.font: font, NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true]
        let made = TextBlockLayout(NSAttributedString(string: text, attributes: attributes), width: width,
                                   lineHeight: resolvedLineHeight, maxLines: maxLines, balanced: balanced)
        cache[width] = made
        return made
    }

    /// Height of the text wrapped at `width`; 0 for empty text.
    public func height(forWidth width: CGFloat) -> CGFloat {
        text.isEmpty ? 0 : layout(forWidth: width).height
    }

    /// Unwrapped advance of the whole text, for shrink-to-fit layouts.
    public var naturalWidth: CGFloat { TextLine(NSAttributedString(string: text, attributes: [.font: font])).width }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: bounds.width > 0 ? height(forWidth: bounds.width) : resolvedLineHeight)
    }

    public override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { needsDisplay = true }
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, !text.isEmpty, bounds.width > 0 else { return }
        // Same smoothing as LabelView (closer to Chromium's glyph weight).
        ctx.setShouldSmoothFonts(true)
        ctx.setAllowsFontSmoothing(true)
        ctx.setFillColor(color.cgColor(in: self))
        layout(forWidth: bounds.width).draw(in: ctx, origin: .zero, width: bounds.width, alignment: alignment)
    }
}
