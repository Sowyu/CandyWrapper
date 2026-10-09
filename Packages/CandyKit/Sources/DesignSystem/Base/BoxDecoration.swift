import AppKit
import QuartzCore

/// One CSS `box-shadow` entry.
public struct BoxShadow: Equatable, Sendable {
    public var x: CGFloat = 0
    public var y: CGFloat = 0
    public var blur: CGFloat = 0
    public var spread: CGFloat = 0
    public var color: NSColor
    public var inset = false

    public init(x: CGFloat = 0, y: CGFloat = 0, blur: CGFloat = 0, spread: CGFloat = 0, color: NSColor, inset: Bool = false) {
        self.x = x; self.y = y; self.blur = blur; self.spread = spread; self.color = color; self.inset = inset
    }

    /// `ring-2 ring-offset-1 ring-offset-background ring-ring`, the focus-visible ring.
    @MainActor
    public static func focusRing(ring: NSColor, offset: NSColor) -> [BoxShadow] {
        [BoxShadow(spread: 1, color: offset), BoxShadow(spread: 3, color: ring)]
    }
}

/// Everything CSS paints for a box, in CSS order: outer shadows, background, inset shadows,
/// border, then the `::before` pseudo element's outer shadows (T3's 1px highlight lines).
public struct BoxStyle: Equatable {
    public var radius: CGFloat = 0
    public var fill: NSColor?
    /// `background-clip`. `.padding` stops the fill inside the border instead of running under it;
    /// `.paddingInLight` is T3's `not-dark:bg-clip-padding`.
    public enum BackgroundClip: Equatable, Sendable { case border, padding, paddingInLight }
    public var backgroundClip = BackgroundClip.border
    public var border: NSColor?
    public var borderWidth: CGFloat = 1
    /// Outer and inset shadows, first entry on top, as in CSS.
    public var shadows: [BoxShadow] = []
    /// Shadows of a `before:absolute before:inset-0 before:rounded-[radius-1]` pseudo element.
    public var beforeShadows: [BoxShadow] = []

    public init() {}
}

/// Paints a `BoxStyle` into a layer that extends past the view by `outset`, so shadows and
/// focus rings can spill outside like CSS. Redraws only when the style or size changes.
@MainActor
public final class BoxDecorationLayer: CALayer {
    public var boxStyle = BoxStyle() { didSet { if boxStyle != oldValue { setNeedsDisplay() } } }
    /// The view whose appearance resolves the dynamic colors.
    public weak var host: NSView?
    /// Room for shadows and the 3px focus ring.
    public let outset: CGFloat = 12

    public override init() {
        super.init()
        needsDisplayOnBoundsChange = true
        isOpaque = false
        actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
    }

    public override init(layer: Any) { super.init(layer: layer) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Sizes the layer around a box of `size` at origin zero in the host's coordinates.
    public func layout(boxSize size: CGSize) {
        frame = CGRect(x: -outset, y: -outset, width: size.width + 2 * outset, height: size.height + 2 * outset)
    }

    public nonisolated override func draw(in ctx: CGContext) {
        // Core Animation calls this on the main thread for layers in a view tree.
        nonisolated(unsafe) let ctx = ctx
        nonisolated(unsafe) let layer = self
        MainActor.assumeIsolated { layer.drawDecoration(in: ctx) }
    }

    private func drawDecoration(in ctx: CGContext) {
        guard let host else { return }
        host.effectiveAppearance.performAsCurrentDrawingAppearance {
            BoxPainter.paint(boxStyle, in: ctx, box: CGRect(x: outset, y: outset,
                                                         width: bounds.width - 2 * outset,
                                                         height: bounds.height - 2 * outset),
                             // Core Animation flips the context itself when the layer tree is flipped
                             // (a flipped host view), so ask the layer, not the view.
                             flipped: contentsAreFlipped())
        }
    }
}

enum BoxPainter {
    static func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
        let r = max(0, min(radius, min(rect.width, rect.height) / 2))
        return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
    }

    /// CSS spread grows the radius with the box (radius + spread), never below zero.
    static func spreadRect(_ box: CGRect, _ radius: CGFloat, _ spread: CGFloat) -> (CGRect, CGFloat) {
        (box.insetBy(dx: -spread, dy: -spread), radius > 0 ? max(0, radius + spread) : 0)
    }

    /// `box` is in a top-left origin space. CALayer contents are y-up unless the context
    /// is flipped, so `yDown` converts CSS y offsets.
    static func paint(_ style: BoxStyle, in ctx: CGContext, box: CGRect, flipped: Bool) {
        let ySign: CGFloat = flipped ? 1 : -1 // CSS +y is down
        let borderPath = rounded(box, style.radius)
        let paddingBox = box.insetBy(dx: style.border == nil ? 0 : style.borderWidth,
                                     dy: style.border == nil ? 0 : style.borderWidth)
        let paddingRadius = max(0, style.radius - (style.border == nil ? 0 : style.borderWidth))
        let paddingPath = rounded(paddingBox, paddingRadius)

        // 1. Outer shadows, last entry painted first.
        for shadow in style.shadows.reversed() where !shadow.inset {
            let (rect, radius) = spreadRect(box, style.radius, shadow.spread)
            let shape = rounded(rect.offsetBy(dx: shadow.x, dy: shadow.y * ySign), radius)
            ctx.saveGState()
            clipOutside(borderPath, in: ctx) // CSS never paints an outer shadow under its box
            paintShadow(of: shape, blur: shadow.blur, color: shadow.color.cgColor, in: ctx)
            ctx.restoreGState()
        }

        // 2. Background.
        if let fill = style.fill {
            // paint() runs with the host's appearance current, so this sees the host's theme.
            let dark = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let clip = style.backgroundClip == .padding || (style.backgroundClip == .paddingInLight && !dark)
            ctx.addPath(clip ? paddingPath : borderPath)
            ctx.setFillColor(fill.cgColor)
            ctx.fillPath()
        }

        // 3. Inset shadows, clipped to the padding box.
        for shadow in style.shadows.reversed() where shadow.inset {
            ctx.saveGState()
            ctx.addPath(paddingPath)
            ctx.clip()
            let (inner, innerRadius) = spreadRect(paddingBox, paddingRadius, -shadow.spread)
            let hole = rounded(inner.offsetBy(dx: shadow.x, dy: shadow.y * ySign), innerRadius)
            let frame = CGMutablePath()
            frame.addRect(paddingBox.insetBy(dx: -shadow.blur * 3 - 40, dy: -shadow.blur * 3 - 40))
            frame.addPath(hole)
            paintShadow(of: frame, evenOdd: true, blur: shadow.blur, color: shadow.color.cgColor, in: ctx)
            ctx.restoreGState()
        }

        // 4. Border ring between the border box and the padding box.
        if let border = style.border {
            let ring = CGMutablePath()
            ring.addPath(borderPath)
            ring.addPath(paddingPath)
            ctx.addPath(ring)
            ctx.setFillColor(border.cgColor)
            ctx.fillPath(using: .evenOdd)
        }

        // 5. `::before` outer shadows: the pseudo element covers the padding box with radius - 1.
        for shadow in style.beforeShadows.reversed() where !shadow.inset {
            let beforePath = rounded(paddingBox, max(0, style.radius - 1))
            let (rect, radius) = spreadRect(paddingBox, max(0, style.radius - 1), shadow.spread)
            ctx.saveGState()
            clipOutside(beforePath, in: ctx)
            paintShadow(of: rounded(rect.offsetBy(dx: shadow.x, dy: shadow.y * ySign), radius),
                        blur: shadow.blur, color: shadow.color.cgColor, in: ctx)
            ctx.restoreGState()
        }
    }

    static func clipOutside(_ path: CGPath, in ctx: CGContext) {
        let clip = CGMutablePath()
        clip.addRect(ctx.boundingBoxOfClipPath.insetBy(dx: -1000, dy: -1000))
        clip.addPath(path)
        ctx.addPath(clip)
        ctx.clip(using: .evenOdd)
    }

    /// Paints only the shadow of `path`. Blur 0 shadows are plain fills (crisp 1px lines).
    static func paintShadow(of path: CGPath, evenOdd: Bool = false, blur: CGFloat, color: CGColor, in ctx: CGContext) {
        if blur <= 0 {
            ctx.addPath(path)
            ctx.setFillColor(color)
            evenOdd ? ctx.fillPath(using: .evenOdd) : ctx.fillPath()
            return
        }
        // Draw the shape far away and cast its shadow back into place, so only the shadow lands.
        let far: CGFloat = 100_000
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: far, height: 0), blur: blur, color: color)
        ctx.translateBy(x: -far, y: 0)
        ctx.addPath(path)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        evenOdd ? ctx.fillPath(using: .evenOdd) : ctx.fillPath()
        ctx.restoreGState()
    }
}
