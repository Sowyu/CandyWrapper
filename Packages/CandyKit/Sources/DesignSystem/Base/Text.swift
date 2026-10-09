import AppKit
import CoreText

/// UI fonts. T3 uses the system stack (`-apple-system`, so SF Pro) and `ui-monospace` (SF Mono),
/// at rem-based sizes from `Tokens.Text`. Weights in use: 400, 500, 600, rarely 700.
public enum DSFont {
    public static func ui(_ px: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: px, weight: weight)
    }

    /// `ui-monospace`: Chromium resolves it to the user fixed-pitch font (Menlo), because SF Mono
    /// is not an installed font. Measured against Chromium in the Input fidelity test.
    public static func mono(_ px: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let base = CTFontCreateUIFontForLanguage(.userFixedPitch, px, nil).map { $0 as NSFont }
            ?? .monospacedSystemFont(ofSize: px, weight: weight)
        return weight >= .semibold ? NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask) : base
    }
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
    public var font: NSFont = DSFont.ui(14) { didSet { invalidate() } }
    public var color: NSColor = ThemeColors.main.color(\.foreground) { didSet { needsDisplay = true } }
    /// CSS line-height in points. Defaults to the font's natural height.
    public var lineHeight: CGFloat? { didSet { invalidate() } }
    public var alignment: NSTextAlignment = .left { didSet { needsDisplay = true } }
    public var truncates = true { didSet { needsDisplay = true } }
    /// `underline` with T3's `underline-offset-4`.
    public var isUnderlined = false { didSet { if isUnderlined != oldValue { needsDisplay = true } } }
    /// CSS `letter-spacing` in points, added after every character like Chromium.
    public var tracking: CGFloat = 0 { didSet { if tracking != oldValue { invalidate() } } }

    public override var wantsUpdateLayer: Bool { false }

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
    }

    private func invalidate() {
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    private var resolvedLineHeight: CGFloat {
        lineHeight ?? ceil(font.ascender - font.descender + font.leading)
    }

    private func attributed() -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        if tracking != 0 { attributes[.kern] = tracking }
        return NSAttributedString(string: text, attributes: attributes)
    }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(textWidth), height: resolvedLineHeight)
    }

    /// The unrounded advance width, for layouts that place text at fractional x like CSS.
    public var textWidth: CGFloat { TextLine(attributed()).width }

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, !text.isEmpty else { return }
        // Core Text's smoothing (stem darkening) matches Chromium's glyph weight better than
        // plain antialiasing: Button fidelity 2.91% differing pixels with it, 3.27% without.
        ctx.setShouldSmoothFonts(true)
        ctx.setAllowsFontSmoothing(true)
        var line = TextLine(attributed())
        if truncates, line.width > bounds.width, bounds.width > 0 {
            let ellipsis = CTLineCreateWithAttributedString(
                NSAttributedString(string: "\u{2026}", attributes: [.font: font, .foregroundColor: color]))
            if let truncated = CTLineCreateTruncatedLine(line.line, Double(bounds.width), .end, ellipsis) {
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
