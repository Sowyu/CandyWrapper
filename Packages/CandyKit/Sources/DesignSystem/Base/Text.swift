import AppKit
import CoreText
import os

/// UI fonts. T3 uses the system stack (`-apple-system`, so SF Pro) and `ui-monospace` (SF Mono),
/// at rem-based sizes from `Tokens.Text`. Weights in use: 400, 500, 600, rarely 700.
public enum DSFont {
    public static func ui(_ px: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        FontRuntime.font(.interface, size: px, weight: weight)
    }

    /// `ui-monospace`: Chromium resolves it to the user fixed-pitch font (Menlo), because SF Mono
    /// is not an installed font. Measured against Chromium in the Input fidelity test.
    public static func mono(_ px: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        FontRuntime.font(.code, size: px, weight: weight)
    }

    /// Fonts made from descriptors are new objects with their own tables and caches (about 150 KB
    /// each), unlike `systemFont`, which AppKit shares. Make each style once.
    public static func cached(_ kind: String, _ px: CGFloat, _ weight: NSFont.Weight, _ make: () -> NSFont) -> NSFont {
        let key = "\(kind) \(px) \(weight.rawValue)"
        return cache.withLockUnchecked { fonts in
            if let font = fonts[key] { return font }
            let font = make()
            fonts[key] = font
            return font
        }
    }

    static func clearCache() { cache.withLockUnchecked { $0.removeAll() } }

    private static let cache = OSAllocatedUnfairLock(uncheckedState: [String: NSFont]())
}

/// Places text the way CSS does: the glyph box (ascent + descent) is centered in the
/// line box, so the baseline sits at half-leading + ascent from the top of each line.
public struct TextLine {
    public let line: CTLine
    public let width: CGFloat
    public let ascent: CGFloat
    public let descent: CGFloat

    public init(_ string: NSAttributedString) {
        line = CTLineCreateWithAttributedString(string)
        var a: CGFloat = 0, d: CGFloat = 0, l: CGFloat = 0
        width = CGFloat(CTLineGetTypographicBounds(line, &a, &d, &l))
        ascent = a
        descent = d
    }

    /// Baseline y (top-left origin) for a line box starting at `top` with CSS `line-height`.
    /// Blink rounds the font's ascent and descent to whole px, then floors the half-leading
    /// (FontMetrics and NGLineHeightMetrics::AddLeading). It lays out in device pixels (zoom for DSF),
    /// so at 2x the rounding is to half points: 12px text in a 16px line sits 0.5pt lower than a
    /// 1x calculation says (Kbd fidelity test).
    // ponytail: assumes the 2x backing store the references use; pass the window's scale for 1x screens
    public func baseline(top: CGFloat, lineHeight: CGFloat, scale: CGFloat = 2) -> CGFloat {
        let a = (ascent * scale).rounded(), d = (descent * scale).rounded()
        return top + (((lineHeight * scale - (a + d)) / 2).rounded(.down) + a) / scale
    }
}

/// Single-style text, drawn once into the layer and redrawn only when it changes.
/// Font smoothing is on: measured closer to Chromium than plain antialiasing.
public final class LabelView: DSView {
    public var text: String = "" { didSet { if text != oldValue { invalidate() } } }
    public var font: NSFont = DSFont.ui(14) { didSet { fontRecipe = FontRuntime.recipe(for: font); if font != oldValue { invalidate() } } }
    private var fontRecipe = FontRuntime.recipe(for: DSFont.ui(14))
    public override func fontRuntimeDidChange() {
        super.fontRuntimeDidChange()
        measuredWidth = nil
        if let recipe = fontRecipe { font = recipe.resolve() }
    }
    // Setters skip unchanged values: rows reconfigure on every streamed delta, and each redraw costs a frame.
    public var color: NSColor = ThemeColors.main.color(\.foreground) {
        didSet {
            guard color != oldValue else { return }
            if Motion.activeTransitions.contains(.color), window != nil, let layer { Motion.crossfade(layer) }
            needsDisplay = true
        }
    }
    /// CSS line-height in points. Defaults to the font's natural height.
    public var lineHeight: CGFloat? { didSet { if lineHeight != oldValue { invalidate() } } }
    public var alignment: NSTextAlignment = .left { didSet { if alignment != oldValue { needsDisplay = true } } }
    /// Truncating labels clip to their box like CSS `truncate` (overflow: hidden). Unclipped,
    /// AppKit gave each one a backing store with room for overflow, about twice the label.
    public var truncates = true { didSet { clipsToBounds = truncates; if truncates != oldValue { needsDisplay = true } } }
    /// Where the ellipsis goes: `.start` is T3's `StartTruncatedPath` (`dir="rtl"` with `text-ellipsis`).
    public var truncation: CTLineTruncationType = .end { didSet { if truncation != oldValue { needsDisplay = true } } }
    /// `underline` with T3's `underline-offset-4`.
    public var isUnderlined = false { didSet { if isUnderlined != oldValue { needsDisplay = true } } }
    /// An underline with its own `underline-offset-*` and `decoration-*` (top edge below the baseline, thickness).
    public var underlineDecoration: (offset: CGFloat, thickness: CGFloat)? {
        didSet { if underlineDecoration?.offset != oldValue?.offset || underlineDecoration?.thickness != oldValue?.thickness { needsDisplay = true } }
    }
    /// CSS `letter-spacing` in points, added after every character like Chromium.
    public var tracking: CGFloat = 0 { didSet { if tracking != oldValue { invalidate() } } }
    /// Core Text font smoothing (stem darkening). Chromium draws text on transparent composited
    /// layers (backdrop-filter surfaces such as the composer) without it, so those labels turn it off.
    public var smoothsFont = true { didSet { if smoothsFont != oldValue { needsDisplay = true } } }
    /// Text appended after `text` in the semibold weight of `font` (a `<span class="font-semibold">`).
    public var emphasizedSuffix: String? { didSet { if emphasizedSuffix != oldValue { invalidate() } } }
    /// UTF-16 offsets drawn semibold in `highlightColor` (a fuzzy match's `<strong>` characters).
    public var highlightedIndices: [Int]? { didSet { if highlightedIndices != oldValue { invalidate() } } }
    public var highlightColor: NSColor? { didSet { if highlightColor != oldValue { needsDisplay = true } } }
    /// The first `count` UTF-16 units in their own color (a search excerpt's "You:" tag).
    public var prefixColor: (count: Int, color: NSColor)? {
        didSet { if prefixColor?.count != oldValue?.count || prefixColor?.color != oldValue?.color { needsDisplay = true } }
    }

    // Static text for VoiceOver, except inside a control, which reads it as its name.
    public override func isAccessibilityElement() -> Bool { !text.isEmpty && !ControlView.isInsideControlElement(self) }
    public override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    public override func accessibilityValue() -> Any? { text + (emphasizedSuffix ?? "") }

    public override var wantsUpdateLayer: Bool { false }
    /// A truncating label clips to its box and draws one line in it.
    public override var drawsWholeBounds: Bool { truncates }

    /// Decoration: clicks go to the control or bar underneath.
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    public convenience init(_ text: String, font: NSFont = DSFont.ui(14), color: NSColor? = nil) {
        self.init(frame: .zero)
        self.text = text
        self.font = font
        if let color { self.color = color }
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.isOpaque = false
        clipsToBounds = truncates
    }

    private func invalidate() {
        measuredWidth = nil
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    /// Layouts ask for the width on every pass (the composer footer measures its pickers each
    /// time), so it is measured once per change of what sets it: text, font, tracking and runs.
    private var measuredWidth: CGFloat?

    private var resolvedLineHeight: CGFloat {
        lineHeight ?? ceil(font.ascender - font.descender + font.leading)
    }

    private func attributed() -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        if tracking != 0 { attributes[.kern] = tracking }
        let result = NSMutableAttributedString(string: text, attributes: attributes)
        if let prefixColor, prefixColor.count <= result.length {
            result.addAttribute(.foregroundColor, value: prefixColor.color, range: NSRange(location: 0, length: prefixColor.count))
        }
        if let emphasizedSuffix {
            attributes[.font] = DSFont.ui(fontRecipe?.size ?? font.pointSize, weight: .semibold)
            result.append(NSAttributedString(string: emphasizedSuffix, attributes: attributes))
        }
        if let highlightedIndices {
            let bold = DSFont.ui(fontRecipe?.size ?? font.pointSize, weight: .semibold)
            for i in highlightedIndices where i < result.length {
                let range = (result.string as NSString).rangeOfComposedCharacterSequence(at: i)
                result.addAttributes([.font: bold, .foregroundColor: highlightColor ?? color], range: range)
            }
        }
        return result
    }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(textWidth), height: resolvedLineHeight)
    }

    /// The unrounded advance width, for layouts that place text at fractional x like CSS.
    public var textWidth: CGFloat {
        if let measuredWidth { return measuredWidth }
        let width = TextLine(attributed()).width
        measuredWidth = width
        return width
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, !text.isEmpty || emphasizedSuffix != nil else { return }
        // Core Text's smoothing (stem darkening) matches Chromium's glyph weight better than
        // plain antialiasing: Button fidelity 2.91% differing pixels with it, 3.27% without.
        ctx.setShouldSmoothFonts(smoothsFont && FontRuntime.smoothing)
        ctx.setAllowsFontSmoothing(smoothsFont && FontRuntime.smoothing)
        var line = TextLine(attributed())
        if truncates, line.width > bounds.width, bounds.width > 0 {
            let ellipsis = CTLineCreateWithAttributedString(
                NSAttributedString(string: "\u{2026}", attributes: [.font: font, .foregroundColor: color]))
            if let truncated = CTLineCreateTruncatedLine(line.line, Double(bounds.width), truncation, ellipsis) {
                line = TextLine(line: truncated)
            }
        }
        let x: CGFloat
        switch alignment {
        case .center: x = (bounds.width - line.width) / 2
        case .right: x = bounds.width - line.width
        default: x = 0
        }
        let baseline = line.baseline(top: (bounds.height - resolvedLineHeight) / 2, lineHeight: resolvedLineHeight)
        ctx.saveGState()
        // Core Text draws in a y-up space; flip around the baseline.
        ctx.textMatrix = .identity
        ctx.translateBy(x: x, y: baseline)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = .zero
        CTLineDraw(line.line, ctx)
        ctx.restoreGState()
        if isUnderlined {
            let thickness = max(1, (font.underlineThickness * 2).rounded() / 2)
            ctx.setFillColor(color.cgColor(in: self))
            ctx.fill(CGRect(x: x, y: baseline + 4 - thickness / 2, width: line.width, height: thickness))
        }
        if let underlineDecoration {
            ctx.setFillColor(color.cgColor(in: self))
            ctx.fill(CGRect(x: x, y: baseline + underlineDecoration.offset, width: line.width, height: underlineDecoration.thickness))
        }
    }
}

extension TextLine {
    init(line: CTLine) {
        self.line = line
        var a: CGFloat = 0, d: CGFloat = 0, l: CGFloat = 0
        width = CGFloat(CTLineGetTypographicBounds(line, &a, &d, &l))
        ascent = a
        descent = d
    }
}
