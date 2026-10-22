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
    /// Per-side border widths (`border-t`, `border-s`). When set, it replaces `borderWidth`.
    public var borderEdges: Edges?
    /// Which corners take `radius`: `.bottom` is `rounded-b-*`.
    public var corners = Corners.all
    /// A frosted pane under classic Glass (a message bubble, a card without a border): it takes a hairline edge and the
    /// top highlight even where T3 draws no border. Bordered see-through boxes get the highlight anyway.
    public var pane = false

    public struct Edges: Equatable, Sendable {
        public var top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat
        public init(top: CGFloat = 0, left: CGFloat = 0, bottom: CGFloat = 0, right: CGFloat = 0) {
            self.top = top; self.left = left; self.bottom = bottom; self.right = right
        }
    }
    /// CSS corners that keep the radius: `.bottom` is `rounded-t-none`, `.leading` is `rounded-e-none`.
    public struct Corners: OptionSet, Equatable, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let topLeft = Corners(rawValue: 1), topRight = Corners(rawValue: 2)
        public static let bottomLeft = Corners(rawValue: 4), bottomRight = Corners(rawValue: 8)
        public static let all: Corners = [.topLeft, .topRight, .bottomLeft, .bottomRight]
        public static let bottom: Corners = [.bottomLeft, .bottomRight]
        public static let top: Corners = [.topLeft, .topRight]
        public static let leading: Corners = [.topLeft, .bottomLeft]
        public static let trailing: Corners = [.topRight, .bottomRight]
    }

    public init() {}
}

/// Paints a `BoxStyle` into a layer that extends past the view by `outset`, so shadows and
/// focus rings can spill outside like CSS. Redraws only when the style or size changes.
@MainActor
public final class BoxDecorationLayer: CALayer {
    public var boxStyle = BoxStyle() {
        didSet {
            guard boxStyle != oldValue else { return }
            let allowed = transition.union(Motion.activeTransitions)
            if !allowed.isEmpty, host?.window != nil, !Motion.reduced, allowed.isSuperset(of: Self.changes(from: oldValue, to: boxStyle)) {
                Motion.crossfade(self)
            }
            setNeedsDisplay()
        }
    }
    /// Properties that always fade on this box, whatever changed them: `.shadow` is `transition-shadow`,
    /// the 150 ms focus ring fade of inputs, checkboxes and badges. A change that touches anything else snaps.
    public var transition: Motion.Transition = []

    /// What differs between two styles, in `transition-*` terms. Geometry counts as nothing animatable.
    static func changes(from a: BoxStyle, to b: BoxStyle) -> Motion.Transition {
        var result: Motion.Transition = []
        if a.fill != b.fill { result.insert(.background) }
        if a.border != b.border { result.insert(.border) }
        if a.shadows != b.shadows || a.beforeShadows != b.beforeShadows { result.insert(.shadow) }
        if a.radius != b.radius || a.backgroundClip != b.backgroundClip || a.borderWidth != b.borderWidth
            || a.borderEdges != b.borderEdges || a.corners != b.corners {
            result.insert(Motion.Transition(rawValue: 0x80))
        }
        return result
    }
    /// The view whose appearance resolves the dynamic colors.
    public weak var host: NSView?
    /// Room for shadows and the 3px focus ring.
    /// Raise it for large shadows (toasts, dialogs); the layer clips at this margin.
    public var outset: CGFloat = 12

    public override init() {
        super.init()
        needsDisplayOnBoundsChange = true
        isOpaque = false
        actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        // 9-slice on the middle pixel: a box that changes size under an animation (a switch thumb
        // stretching, a card riding a collapsible) keeps its corners, border and shadow edges. At rest
        // the image matches the bounds, so this changes no pixels.
        contentsCenter = CGRect(x: 0.5, y: 0.5, width: 0, height: 0)
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
    /// A rect with only `corners` (CSS sides) rounded. `flipped` says whether +y is down.
    static func cornerRounded(_ rect: CGRect, _ radius: CGFloat, corners: BoxStyle.Corners, flipped: Bool) -> CGPath {
        let r = max(0, min(radius, min(rect.width, rect.height) / 2))
        if corners == .all || r == 0 { return rounded(rect, r) }
        let (top, bottom) = flipped ? (rect.minY, rect.maxY) : (rect.maxY, rect.minY)
        let path = CGMutablePath()
        // From the middle of the top edge, clockwise in CSS terms: top-right, bottom-right, bottom-left, top-left.
        let points: [(CGPoint, BoxStyle.Corners)] = [(CGPoint(x: rect.maxX, y: top), .topRight), (CGPoint(x: rect.maxX, y: bottom), .bottomRight),
                                                     (CGPoint(x: rect.minX, y: bottom), .bottomLeft), (CGPoint(x: rect.minX, y: top), .topLeft)]
        path.move(to: CGPoint(x: rect.midX, y: top))
        for i in 0..<4 {
            let (p, corner) = points[i]
            let next = points[(i + 1) % 4].0
            if corners.contains(corner) { path.addArc(tangent1End: p, tangent2End: next, radius: r) } else { path.addLine(to: p) }
        }
        path.closeSubpath()
        return path
    }

    static func paint(_ style: BoxStyle, in ctx: CGContext, box: CGRect, flipped: Bool) {
        // Dither (after Capy) tightens every box's corners to its two radii.
        // Its corners are continuous (SmoothCorners).
        var style = style
        let smooth = ThemeRuntime.isDither(dark: NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        if smooth { style.radius = DitherChrome.radius(style.radius) }
        let ySign: CGFloat = flipped ? 1 : -1 // CSS +y is down
        let shape: (CGRect, CGFloat) -> CGPath = { rect, radius in
            smooth ? SmoothCorners.path(rect, radius, corners: style.corners, flipped: flipped)
                : cornerRounded(rect, radius, corners: style.corners, flipped: flipped)
        }
        let borderPath = shape(box, style.radius)
        let w = style.border == nil ? 0 : style.borderWidth
        let e = style.border == nil ? BoxStyle.Edges() : style.borderEdges ?? BoxStyle.Edges(top: w, left: w, bottom: w, right: w)
        // CSS top is the context's maxY when the context is y-up.
        let paddingBox = CGRect(x: box.minX + e.left, y: box.minY + (flipped ? e.top : e.bottom),
                                width: box.width - e.left - e.right, height: box.height - e.top - e.bottom)
        let paddingRadius = max(0, style.radius - max(e.top, e.left, e.bottom, e.right))
        let paddingPath = shape(paddingBox, paddingRadius)

        // Classic Glass frosts every box: soft drop shadows shrink to a hairline's worth, since depth comes from
        // the panes' density (docs/design.md "Glass").
        let frost = WindowGlass.frostDrawing()
        let outerShadows = frost ? style.shadows.map(WindowGlass.frostShadow) : style.shadows

        // 1. Outer shadows, last entry painted first.
        for shadow in outerShadows.reversed() where !shadow.inset {
            let (rect, radius) = spreadRect(box, style.radius, shadow.spread)
            let shadowShape = shape(rect.offsetBy(dx: shadow.x, dy: shadow.y * ySign), radius)
            ctx.saveGState()
            clipOutside(borderPath, in: ctx) // CSS never paints an outer shadow under its box
            paintShadow(of: shadowShape, blur: shadow.blur, color: shadow.color.cgColor, in: ctx)
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
            let holeRect = inner.offsetBy(dx: shadow.x, dy: shadow.y * ySign)
            let hole = smooth ? SmoothCorners.path(holeRect, innerRadius, flipped: flipped) : rounded(holeRect, innerRadius)
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

        // 4b. A frosted pane's top highlight: a bordered box with a see-through fill catches light on its top edge.
        if frost, style.pane, style.border == nil {
            let ring = CGMutablePath()
            ring.addPath(borderPath)
            ring.addPath(shape(box.insetBy(dx: 1, dy: 1), max(0, style.radius - 1)))
            ctx.addPath(ring)
            ctx.setFillColor(WindowGlass.edge.cgColor)
            ctx.fillPath(using: .evenOdd)
        }
        if frost, style.pane || style.border != nil, style.borderEdges == nil, let fill = style.fill, case let a = fill.cgColor.alpha, a > 0, a < 1,
           box.height >= 16, style.corners.contains(.topLeft) || style.corners.contains(.topRight) || style.radius == 0 {
            ctx.saveGState()
            ctx.addPath(paddingPath)
            ctx.clip()
            let inner = style.border == nil ? box.insetBy(dx: 1, dy: 1) : paddingBox
            let y = flipped ? inner.minY : inner.maxY - 1
            ctx.setFillColor(WindowGlass.highlight.cgColor)
            ctx.fill(CGRect(x: inner.minX, y: y, width: inner.width, height: 1))
            ctx.restoreGState()
        }

        // 5. `::before` outer shadows: the pseudo element covers the padding box with radius - 1.
        for shadow in style.beforeShadows.reversed() where !shadow.inset {
            let beforePath = shape(paddingBox, max(0, style.radius - 1))
            let (rect, radius) = spreadRect(paddingBox, max(0, style.radius - 1), shadow.spread)
            ctx.saveGState()
            clipOutside(beforePath, in: ctx)
            paintShadow(of: shape(rect.offsetBy(dx: shadow.x, dy: shadow.y * ySign), radius),
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

/// A plain box painted with a `BoxStyle`: cards, panels and list frames. Subviews sit on top.
open class BoxView: DSView {
    public let decoration = BoxDecorationLayer()
    public var boxStyle: BoxStyle {
        get { decoration.boxStyle }
        set { decoration.boxStyle = newValue }
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        decoration.host = self
        layer?.addSublayer(decoration)
        layer?.masksToBounds = false
    }

    open override func layout() {
        super.layout()
        decoration.layout(boxSize: bounds.size)
    }

    open override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        decoration.setNeedsDisplay()
    }
}
