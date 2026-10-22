import AppKit

/// The surfaces T3's popups paint (ui-components-a.md 1.3, 9, 11, 13-15).
@MainActor
public enum PopupSurface {
    case glass        // Menu, Select, Combobox, Popover: `dropdown-glass` plus the deep drop shadow
    case opaque       // Autocomplete: `border bg-popover shadow-lg/5` and the ::before line
    case tooltip      // Tooltip default: `border bg-popover shadow-md/5` and the ::before line
    case tooltipGlass // Tooltip glass: `dropdown-glass shadow-xl shadow-black/25 before:hidden`

    /// `dropdown-glass`'s alpha: popover at 18% plus 82% of popover at `--glass-opacity` (83.6% at T3's 80%).
    public static var dropdownGlassAlpha: CGFloat { 0.18 + 0.82 * ThemeRuntime.glassOpacity }

    /// `dropdown-glass` over a uniform `--background`, composited. Built when a surface restyles, which
    /// a glass opacity change triggers.
    // ponytail: solid color instead of a live 12/16px backdrop blur; identical over flat backgrounds, use an
    // NSVisualEffectView-like blur if popups ever sit over busy content and users notice
    /// Classic Glass shows the popover's own frosted pane over a live blur instead (`WindowGlass.Level.floating`).
    public static var glassFill: NSColor {
        let solid = Themed.color(\.popover).blended(over: Themed.color(\.background), alpha: dropdownGlassAlpha)
        let pane = Themed.color(\.popover)
        return NSColor(name: nil) { ThemeRuntime.framesPanes(dark: $0.isDark) ? WindowGlass.resolve(pane, in: $0) : WindowGlass.resolve(solid, in: $0) }
    }

    /// `--popover-foreground` through the contrast layer.
    static var text: NSColor { Themed.color(\.contrastPopoverForeground) }

    public func box(radius: CGFloat = 10, beforeLine: Bool = false) -> BoxStyle {
        var box = BoxStyle()
        box.radius = radius
        switch self {
        case .glass, .tooltipGlass:
            box.fill = Self.glassFill
            let stock = Themed.color(\.contrastForeground, 0.1)
            box.border = NSColor(name: nil) { ThemeRuntime.isDither(dark: $0.isDark) ? DitherChrome.rim(dark: $0.isDark) : WindowGlass.resolve(stock, in: $0) }
            if self == .glass {
                box.shadows = [BoxShadow(y: 16, blur: 40, spread: -18, color: Themed.pick(light: Themed.black(0.55), dark: .clear)),
                               BoxShadow(y: 18, blur: 44, spread: -18, color: Themed.pick(light: .clear, dark: Themed.black(0.8)))]
            } else {
                box.shadows = [BoxShadow(y: 20, blur: 25, spread: -5, color: Themed.black(0.25)),
                               BoxShadow(y: 8, blur: 10, spread: -6, color: Themed.black(0.25))]
            }
        case .opaque, .tooltip:
            box.fill = Themed.color(\.popover)
            box.border = Themed.color(\.contrastBorder)
            box.backgroundClip = .paddingInLight
            box.shadows = self == .opaque
                ? [BoxShadow(y: 10, blur: 15, spread: -3, color: Themed.black(0.05)), BoxShadow(y: 4, blur: 6, spread: -4, color: Themed.black(0.05))]
                : [BoxShadow(y: 4, blur: 6, spread: -1, color: Themed.black(0.05)), BoxShadow(y: 2, blur: 4, spread: -2, color: Themed.black(0.05))]
        }
        if beforeLine || self == .opaque || self == .tooltip {
            box.beforeShadows = [BoxShadow(y: 1, color: Themed.pick(light: Themed.black(0.04), dark: .clear)),
                                 BoxShadow(y: -1, color: Themed.pick(light: .clear, dark: Themed.white(0.06)))]
        }
        return box
    }

    /// The surface's drop shadows, for `PopupShadowLayer`. The box itself paints none of them.
    func split(radius: CGFloat = 10, beforeLine: Bool = false) -> (box: BoxStyle, shadows: [BoxShadow]) {
        var b = box(radius: radius, beforeLine: beforeLine)
        let shadows = b.shadows
        b.shadows = []
        return (b, shadows)
    }
}

/// Drop shadows for popup surfaces, painted with BoxPainter into a 64pt outset. BoxDecorationLayer's
/// 12pt outset clips the 40px blur of `dropdown-glass` popups into a visible rectangle.
@MainActor
final class PopupShadowLayer: CALayer {
    var shadows: [BoxShadow] = [] { didSet { setNeedsDisplay() } }
    var radius: CGFloat = 10 { didSet { setNeedsDisplay() } }
    weak var host: NSView?
    let outset: CGFloat = 64

    override init() {
        super.init()
        isOpaque = false
        needsDisplayOnBoundsChange = true
        actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
    }
    override init(layer: Any) { super.init(layer: layer) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func update(boxSize size: CGSize) {
        frame = CGRect(x: -outset, y: -outset, width: size.width + 2 * outset, height: size.height + 2 * outset)
        setNeedsDisplay()
    }

    nonisolated override func draw(in ctx: CGContext) {
        nonisolated(unsafe) let ctx = ctx
        nonisolated(unsafe) let layer = self
        MainActor.assumeIsolated {
            guard let host = layer.host else { return }
            var style = BoxStyle()
            style.radius = layer.radius
            style.shadows = layer.shadows
            let box = layer.bounds.insetBy(dx: layer.outset, dy: layer.outset)
            host.effectiveAppearance.performAsCurrentDrawingAppearance {
                BoxPainter.paint(style, in: ctx, box: box, flipped: layer.contentsAreFlipped())
            }
        }
    }
}

/// Draws one line of text with CSS `letter-spacing` (MenuShortcut's `tracking-widest`).
final class TrackedLabelView: DSView {
    var text: String { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var font: NSFont
    var tracking: CGFloat
    var color: NSColor { didSet { needsDisplay = true } }
    var lineHeight: CGFloat

    init(_ text: String, font: NSFont, tracking: CGFloat, color: NSColor, lineHeight: CGFloat) {
        self.text = text; self.font = font; self.tracking = tracking; self.color = color; self.lineHeight = lineHeight
        super.init(frame: .zero)
        layer?.isOpaque = false
    }

    override var wantsUpdateLayer: Bool { false }

    private var line: TextLine { TextLine(NSAttributedString(string: text, attributes: [.font: font, .kern: tracking, .foregroundColor: color])) }
    override var intrinsicContentSize: NSSize { NSSize(width: line.width, height: lineHeight) }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, !text.isEmpty else { return }
        ctx.setShouldSmoothFonts(FontRuntime.smoothing)
        ctx.setAllowsFontSmoothing(FontRuntime.smoothing)
        let l = line
        ctx.textMatrix = .identity
        ctx.translateBy(x: 0, y: l.baseline(top: (bounds.height - lineHeight) / 2, lineHeight: lineHeight))
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = .zero
        CTLineDraw(l.line, ctx)
    }
}
