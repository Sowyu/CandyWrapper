import AppKit
import DesignSystem

/// Zoom maths shared by the chat image preview and the agent image gallery. Scales are relative to the picture's fitted
/// size, so 1 is fit; `actual` is the scale that shows the picture's own pixels one to one.
public enum ImageZoom {
    /// The picture's new origin after zooming from `scale` to `target` so the picture point under `point` stays there.
    public static func anchored(origin: CGPoint, scale: CGFloat, to target: CGFloat, about point: CGPoint) -> CGPoint {
        let k = target / max(scale, .ulpOfOne)
        return CGPoint(x: point.x - (point.x - origin.x) * k, y: point.y - (point.y - origin.y) * k)
    }

    /// Keeps a `size` picture covering `bounds` on each axis it overflows, and centred on each axis it doesn't.
    public static func clamp(origin: CGPoint, size: CGSize, in bounds: CGSize) -> CGPoint {
        func axis(_ o: CGFloat, _ s: CGFloat, _ b: CGFloat) -> CGFloat { s <= b ? ((b - s) / 2).rounded() : min(0, max(b - s, o)) }
        return CGPoint(x: axis(origin.x, size.width, bounds.width), y: axis(origin.y, size.height, bounds.height))
    }

    /// The scale that shows `natural` pixels one to one at `backing` pixels per point, for a picture fitted at `fitted`.
    public static func actual(natural: CGSize?, fitted: CGSize, backing: CGFloat) -> CGFloat {
        guard let natural, natural.width > 0, fitted.width > 0 else { return 1 }
        return natural.width / max(backing, 1) / fitted.width
    }

    /// Never below fit; up to 8 times the picture's pixels, and at least 2x fit so a small picture can still be enlarged.
    public static func limits(actual: CGFloat) -> ClosedRange<CGFloat> { 1...max(2, 8 * actual) }

    /// Double-click and smart zoom: a zoomed picture goes back to fit; a fitted one goes to its pixels one to one, or
    /// to twice the fit when fit already shows them at that size or larger.
    public static func toggle(scale: CGFloat, actual: CGFloat) -> CGFloat {
        if scale > 1.01 { return 1 }
        return actual > 1.01 ? actual : 2
    }

    /// ⌘+ and ⌘- multiply by this.
    public static let step: CGFloat = 1.5

    /// The pixel side to decode for a picture shown `shown` points large: the screen's pixels, never past the picture's
    /// own, in 256-pixel steps so a pinch doesn't decode on every frame.
    public static func decodeSide(shown: CGSize, backing: CGFloat, natural: CGSize?) -> Int {
        var side = max(shown.width, shown.height) * backing
        if let natural, natural.width > 0 { side = min(side, max(natural.width, natural.height)) }
        return max(256, Int((side / 256).rounded(.up)) * 256)
    }

    /// ⌘= or ⌘+ zoom in, ⌘- out, ⌘0 fits; nil for any other key.
    public static func command(_ event: NSEvent) -> Int? {
        guard event.type == .keyDown,
              event.modifierFlags.intersection([.command, .control, .option]) == .command else { return nil }
        switch event.charactersIgnoringModifiers {
        case "=", "+": return 1
        case "-": return -1
        case "0": return 0
        default: return nil
        }
    }
}

/// A picture that zooms inside its own bounds: pinch about the pointer, smart zoom or double-click to toggle fit and
/// 100%, ⌘+ ⌘- ⌘0, and two-finger scroll or a drag to pan while zoomed. It never zooms below fit. Animates only for a
/// toggle or a shortcut, and not under Reduce Motion; gestures follow the fingers.
final class ZoomableImageView: DSView {
    let picture: AsyncImageView
    /// The picture's natural pixel size, nil while unknown.
    var naturalSize: () -> CGSize? = { nil }
    /// The picture's size at fit in `area`. The default fills the area, for hosts that size this view to the fit.
    var fit: (_ natural: CGSize, _ area: CGSize, _ backing: CGFloat) -> CGSize = { _, area, _ in area }
    /// A click that lands beside the picture.
    var onBackgroundClick: (() -> Void)?
    /// A scroll while at fit, which a host may take (the large view's swipe); without one it passes on.
    var onFitScroll: ((NSEvent) -> Void)?

    private(set) var scale: CGFloat = 1
    private var origin = CGPoint.zero
    private var drag: (point: CGPoint, origin: CGPoint)?
    private var dragged = false

    init(picture: AsyncImageView) {
        self.picture = picture
        super.init(frame: .zero)
        layer?.masksToBounds = true
        addSubview(picture)
        toolTip = "Pinch or ⌘+ and ⌘- to zoom, ⌘0 to fit. Double-click toggles 100%."
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    var isZoomed: Bool { scale > 1.001 }

    private var backing: CGFloat { window?.backingScaleFactor ?? 2 }

    var fittedSize: CGSize {
        guard let natural = naturalSize(), natural.width > 0, natural.height > 0 else { return bounds.size }
        return fit(natural, bounds.size, backing)
    }

    private var actual: CGFloat { ImageZoom.actual(natural: naturalSize(), fitted: fittedSize, backing: backing) }

    /// Back to fit at once, as for a new picture.
    func reset() {
        scale = 1
        drag = nil
        needsLayout = true
        updateAccessibility()
    }

    override func layout() {
        super.layout()
        let fitted = fittedSize
        let size = CGSize(width: (fitted.width * scale).rounded(), height: (fitted.height * scale).rounded())
        origin = ImageZoom.clamp(origin: origin, size: size, in: bounds.size)
        picture.frame = NSRect(origin: origin, size: size)
        // At fit, exactly the shown size, as before zooming existed; zoomed, in steps.
        picture.requestedSide = isZoomed ? ImageZoom.decodeSide(shown: size, backing: backing, natural: naturalSize())
            : Int((max(size.width, size.height) * backing).rounded(.up))
    }

    /// Zooms to `target` (clamped) about `point`, or the middle of the view.
    func zoom(to target: CGFloat, about point: CGPoint? = nil, animated: Bool = false) {
        let clamped = min(ImageZoom.limits(actual: actual).upperBound, max(1, target))
        guard abs(clamped - scale) > 0.0001 else { return }
        let p = point ?? CGPoint(x: bounds.midX, y: bounds.midY)
        layoutSubtreeIfNeeded()
        origin = ImageZoom.anchored(origin: picture.frame.origin, scale: scale, to: clamped, about: p)
        scale = clamped
        updateAccessibility()
        if animated, !Motion.reduced {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = RedesignTokens.Motion.quick
                ctx.timingFunction = RedesignTokens.Motion.curve
                ctx.allowsImplicitAnimation = true
                layout()
            }
        } else {
            needsLayout = true
        }
        window?.invalidateCursorRects(for: self)
    }

    /// The level as a share of the picture's own pixels, for VoiceOver.
    private func updateAccessibility() {
        let percent = Int((scale / max(actual, .ulpOfOne) * 100).rounded())
        picture.setAccessibilityValue("Zoom \(percent)%")
    }

    func handleZoomKey(_ direction: Int) {
        switch direction {
        case 1: zoom(to: scale * ImageZoom.step, animated: true)
        case -1: zoom(to: scale / ImageZoom.step, animated: true)
        default: zoom(to: 1, animated: true)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window != nil, !isHiddenOrHasHiddenAncestor, let direction = ImageZoom.command(event) else {
            return super.performKeyEquivalent(with: event)
        }
        handleZoomKey(direction)
        return true
    }

    override func magnify(with event: NSEvent) {
        zoom(to: scale * (1 + event.magnification), about: convert(event.locationInWindow, from: nil))
    }

    override func smartMagnify(with event: NSEvent) {
        zoom(to: ImageZoom.toggle(scale: scale, actual: actual), about: convert(event.locationInWindow, from: nil), animated: true)
    }

    override func scrollWheel(with event: NSEvent) {
        guard isZoomed else {
            if let onFitScroll { onFitScroll(event) } else { super.scrollWheel(with: event) }
            return
        }
        let k: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 16
        origin = CGPoint(x: picture.frame.minX + event.scrollingDeltaX * k, y: picture.frame.minY + event.scrollingDeltaY * k)
        needsLayout = true
    }

    override func resetCursorRects() {
        if isZoomed { addCursorRect(picture.frame.intersection(bounds), cursor: drag != nil ? .closedHand : .openHand) }
    }

    override func mouseDown(with event: NSEvent) {
        dragged = false
        drag = isZoomed ? (convert(event.locationInWindow, from: nil), picture.frame.origin) : nil
        if drag != nil { NSCursor.closedHand.set() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag else { return }
        let p = convert(event.locationInWindow, from: nil)
        if hypot(p.x - drag.point.x, p.y - drag.point.y) > 4 { dragged = true }
        origin = CGPoint(x: drag.origin.x + p.x - drag.point.x, y: drag.origin.y + p.y - drag.point.y)
        needsLayout = true
    }

    override func mouseUp(with event: NSEvent) {
        let wasDragging = drag != nil
        drag = nil
        let p = convert(event.locationInWindow, from: nil)
        if !dragged {
            if event.clickCount == 2 { zoom(to: ImageZoom.toggle(scale: scale, actual: actual), about: p, animated: true) }
            else if event.clickCount == 1, !picture.frame.contains(p) { onBackgroundClick?() }
        }
        if wasDragging { window?.invalidateCursorRects(for: self) }
    }
}
