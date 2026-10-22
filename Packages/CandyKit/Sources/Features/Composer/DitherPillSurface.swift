import AppKit
import DesignSystem

/// Redesign's floating chrome for everything around the composer (the user, 2026-10-22: "no more things sticking out of
/// the prompt field, only floating rounded rectangle pills"): the composer's frosted glass, a hairline border and a
/// soft drop shadow, on continuous corners. Pills (chips, Stash, notices) are 28pt with control corners; panels
/// (approvals, the queue, the stash list) use card corners. Nothing draws while idle: the shadow has a fixed path.
public enum DitherPill {
    public static let height: CGFloat = 28
    /// Control corners. Rows of pills sit `inset` in from the composer's sides, so a pill's smaller corner stays
    /// inside the composer's 16pt curve instead of looking like it hangs off it (the user, 2026-10-22).
    public static let radius: CGFloat = DitherChrome.controlRadius
    public static let inset: CGFloat = DitherChrome.panelRadius - DitherChrome.controlRadius
    /// Between the composer and the first row, between rows, and between pills in a row.
    public static let gap: CGFloat = 8
    public static let spacing: CGFloat = 6

    @MainActor public static func fill(in view: NSView) -> CGColor {
        let dark = view.effectiveAppearance.isDark
        return Themed.color(dark ? \.surfaceRaised : \.card).cgColor(in: view).copy(alpha: 0.62)!
    }

    @MainActor public static func border(dark: Bool) -> CGColor { (dark ? Themed.white(0.08) : Themed.black(0.08)).cgColor }

    /// Under the product shadow ceiling in light; a little deeper in dark, where a lighter shadow vanishes.
    @MainActor public static func shadow(_ layer: CALayer, path: CGRect, radius: CGFloat, dark: Bool) {
        layer.shadowColor = Themed.black(1).cgColor
        layer.shadowOpacity = dark ? 0.28 : 0.08
        layer.shadowRadius = 4
        layer.shadowOffset = CGSize(width: 0, height: layer.isGeometryFlipped ? 2 : -2)
        layer.shadowPath = SmoothCorners.path(path, radius, flipped: false)
    }

    /// The motion for a pill that appears: up 4pt and in from clear, 150 ms on Capy's curve.
    @MainActor public static func animateIn(_ view: NSView) {
        guard !Motion.reduced, let layer = view.layer else { return }
        let rise = CABasicAnimation(keyPath: "transform.translation.y")
        rise.fromValue = 4
        rise.toValue = 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        for a in [rise, fade] {
            a.duration = 0.15
            a.timingFunction = curve
            layer.add(a, forKey: "pill.in." + a.keyPath!)
        }
    }

    /// Capy's ease (`cubic-bezier(0.23, 1, 0.32, 1)`, capy-design.md).
    @MainActor public static let curve = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
}

/// The pill chrome as a view, placed under a control that draws no surface of its own (the chips, the checkout and
/// branch controls). Lets clicks through.
public final class DitherPillSurface: DSView {
    public var radius: CGFloat = DitherPill.radius { didSet { if radius != oldValue { needsLayout = true } } }
    private let shade = DSView()
    private let blur = BackdropBlurView()
    private let face = DSView()

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.masksToBounds = false
        face.layer?.borderWidth = 1
        face.layer?.masksToBounds = true
        for v in [shade, blur, face] { addSubview(v) }
        setAccessibilityElement(false)
    }

    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    public override func updateLayer() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        face.layer?.backgroundColor = DitherPill.fill(in: self)
        face.layer?.borderColor = DitherPill.border(dark: effectiveAppearance.isDark)
        CATransaction.commit()
        needsLayout = true
    }

    public override func layout() {
        super.layout()
        let r = min(radius, bounds.height / 2)
        for v in [shade, blur, face] { v.frame = bounds }
        blur.cornerRadius = r
        CATransaction.begin(); CATransaction.setDisableActions(true)
        face.layer?.cornerRadius = r
        shade.layer?.masksToBounds = false
        DitherPill.shadow(shade.layer!, path: shade.bounds, radius: r, dark: effectiveAppearance.isDark)
        shade.layer?.mask = DitherPill.outsideMask(shade.bounds, radius: r, existing: shade.layer?.mask)
        CATransaction.commit()
    }
}

extension DitherPill {
    /// Keeps a shadow outside its shape, so it never darkens the see-through glass above it.
    @MainActor static func outsideMask(_ rect: CGRect, radius: CGFloat, existing: CALayer?) -> CALayer {
        let mask = existing as? CAShapeLayer ?? CAShapeLayer()
        let path = CGMutablePath()
        path.addRect(rect.insetBy(dx: -24, dy: -24))
        path.addPath(SmoothCorners.path(rect, radius, flipped: false))
        mask.fillRule = .evenOdd
        mask.frame = CGRect(origin: .zero, size: rect.size)
        mask.path = path
        return mask
    }
}
