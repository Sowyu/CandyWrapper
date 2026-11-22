import AppKit
import DesignSystem

/// Redesign: what lies over a thread's rows where they run up through the header row (the user, 2026-11-22: "i want
/// text able to go back here, i want no fade up here except at the very very top"). The rows draw at full strength up
/// to the window's top edge. Two small things sit over them:
/// - a backdrop blur only behind the breadcrumb's text, with soft edges, so a row passing behind keeps the title
///   readable. It is an `NSVisualEffectView` blending within the window, its material's tint layers hidden and its
///   shape cut by a nine-slice `maskImage`, so the mask is patch-sized, never timeline-sized. A light wash of the band
///   color in the same soft shape sits over it (`patchTint`). Under Reduce Transparency the patch is solid band color.
/// - a fade of the band's color over the top `edgeFade` points, so a row doesn't meet the window's edge hard. The art
///   already fades from the band color there (`DitherChrome.bandColor`), so the strip doesn't cut it.
///
/// The blur is the window server's: it costs only while what lies under the patch changes and nothing while the thread
/// sits still. Offscreen snapshots draw the edge fade and, under Reduce Transparency, the solid patch.
final class ThreadHeaderShadeView: DSView {
    /// How tall the fade at the window's top edge is: band color at the edge to none at this depth.
    static let edgeFade: CGFloat = 8
    /// Room around the breadcrumb's text where the blur is whole, and the soft edge outside it.
    static let patchPad = NSSize(width: 8, height: 2)
    static let patchFeather: CGFloat = 8
    /// The band color inside the patch over the blur. The blur alone left Blur's picture showing through brighter and
    /// more saturated than around it, a visible box; this much evens it out and keeps the title's contrast.
    static let patchTint: CGFloat = 0.3

    private let blur = HeaderBlurView()
    private let fill = CALayer()
    private let edge = CAGradientLayer()
    private var solid: Bool?
    /// The breadcrumb's text in this view's coordinates; empty hides the patch.
    var textRect = NSRect.zero { didSet { if textRect != oldValue { needsLayout = true } } }

    /// The patch's frame: the text, its padding, then the feather.
    static func patchFrame(_ text: NSRect) -> NSRect {
        text.isEmpty ? .zero : text.insetBy(dx: -(patchPad.width + patchFeather), dy: -(patchPad.height + patchFeather)).integral
    }

    /// Smoothstep from 0 at `t = 0` to 1 at `t = 1`.
    private static func ease(_ t: Double) -> Double { let x = min(1, max(0, t)); return x * x * (3 - 2 * x) }

    /// The edge fade's opacity at `t`, 0 at the window's top edge to 1 at `edgeFade` below it.
    static func edge(_ t: Double) -> Double { 1 - ease(t) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(blur)
        blur.maskImage = Self.patchShape
        fill.actions = ["bounds": NSNull(), "position": NSNull(), "contents": NSNull(), "hidden": NSNull(), "opacity": NSNull()]
        fill.contentsCenter = Self.shapeCenter
        edge.actions = ["bounds": NSNull(), "position": NSNull(), "colors": NSNull(), "locations": NSNull()]
        layer?.addSublayer(fill)
        layer?.addSublayer(edge)
        setAccessibilityElement(false)
        // Reduce Transparency and "Ignore Reduce Transparency" swap the blur for the solid patch.
        NotificationCenter.default.addObserver(self, selector: #selector(displayChanged), name: ThemeRuntime.didChange, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(displayChanged),
                                                          name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    @objc private func displayChanged() {
        needsDisplay = true; needsLayout = true
        superview?.needsLayout = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Where the patch sits now, in this view's coordinates.
    var patchFrame: NSRect { Self.patchFrame(textRect) }

    override func layout() {
        super.layout()
        let solid = ThemeRuntime.reducesTransparency(), patch = patchFrame
        blur.isHidden = solid || patch.isEmpty
        blur.frame = patch
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fill.frame = patch
        fill.isHidden = patch.isEmpty
        fill.opacity = solid ? 1 : Float(Self.patchTint)
        edge.frame = CGRect(x: 0, y: 0, width: bounds.width, height: Self.edgeFade)
        CATransaction.commit()
        if solid != self.solid { self.solid = solid; needsDisplay = true }
    }

    override func updateLayer() {
        super.updateLayer()
        let band = DitherChrome.bandColor(in: self)
        let ts = (0...6).map { Double($0) / 6 }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        edge.locations = ts.map { NSNumber(value: $0) }
        edge.colors = ts.map { band.copy(alpha: Self.edge($0))! }
        fill.contents = Self.shapeImage(band)
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

    /// The patch's soft shape as a nine-slice image: whole inside, easing to nothing across the feather at every side.
    /// Its middle row and column stretch, so one small image fits any title.
    private static let shapeSide = Int(2 * patchFeather + 1)
    private static let shapeCenter = CGRect(x: patchFeather / CGFloat(shapeSide), y: patchFeather / CGFloat(shapeSide),
                                            width: 1 / CGFloat(shapeSide), height: 1 / CGFloat(shapeSide))
    private static func shapeImage(_ color: CGColor) -> CGImage? {
        let side = shapeSide, scale = 2, px = side * scale, f = Double(patchFeather)
        guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        let c = color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components ?? [0, 0, 0, 1]
        for y in 0..<px {
            for x in 0..<px {
                // Distance into the feather from the whole middle, per axis, rounded at the corners.
                let dx = max(0, f - (Double(x) + 0.5) / Double(scale)), dy = max(0, f - (Double(y) + 0.5) / Double(scale))
                let ex = max(0, (Double(x) + 0.5) / Double(scale) - (f + 1)), ey = max(0, (Double(y) + 0.5) / Double(scale) - (f + 1))
                let d = (pow(max(dx, ex), 2) + pow(max(dy, ey), 2)).squareRoot()
                let a = (1 - ease(d / f)) * Double(c.count > 3 ? c[3] : 1)
                ctx.setFillColor(red: c[0], green: c[1], blue: c[2], alpha: a)
                ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return ctx.makeImage()
    }
    private static let patchShape: NSImage = {
        let image = NSImage(cgImage: shapeImage(CGColor(gray: 0, alpha: 1))!, size: NSSize(width: shapeSide, height: shapeSide))
        image.capInsets = NSEdgeInsets(top: patchFeather, left: patchFeather, bottom: patchFeather, right: patchFeather)
        image.resizingMode = .stretch
        return image
    }()
}

/// The system backdrop blur inside the window with the material's color layers hidden, so the ground shows through
/// in its own color. Public API only: the radius is the material's, the shape comes from `maskImage`.
// ponytail: hides the effect view's non-backdrop sublayers by class name; if a macOS update renames them the material
// tints the patch, revisit on each new macOS.
private final class HeaderBlurView: NSVisualEffectView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        blendingMode = .withinWindow
        material = .underWindowBackground
        state = .active
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func updateLayer() { super.updateLayer(); untint() }
    override func layout() { super.layout(); untint() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); untint() }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        DispatchQueue.main.async { [weak self] in self?.untint() }
    }

    private func untint() {
        guard let root = layer else { return }
        var found = false
        func walk(_ l: CALayer) {
            for s in l.sublayers ?? [] {
                if NSStringFromClass(type(of: s)).contains("Backdrop") { found = true; continue }
                if s.sublayers?.isEmpty == false { walk(s) } else if !s.isHidden { s.isHidden = true }
            }
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        walk(root)
        CATransaction.commit()
        // Without a backdrop the material would only tint: show nothing.
        let alpha: CGFloat = found || root.sublayers?.isEmpty != false ? 1 : 0
        if alphaValue != alpha { alphaValue = alpha }
    }
}
