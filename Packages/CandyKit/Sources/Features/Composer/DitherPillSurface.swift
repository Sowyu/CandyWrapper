import AppKit
import DesignSystem

/// Redesign's floating chrome for everything around the composer (the user, 2026-10-22: "no more things sticking out of
/// the prompt field, only floating rounded rectangle pills"): the composer's solid surface, a hairline border and a
/// soft drop shadow, on continuous corners. Pills (chips, Stash, notices) are 30pt; they and the panels (approvals,
/// the queue, the stash list) share the composer's one surface corner. Nothing draws while idle: the shadow has a fixed path.
public enum DitherPill {
    public static let height: CGFloat = RedesignTokens.Space.pill
    /// The composer's corner. Rows of pills sit `inset` in from the composer's sides, so a pill's corner never hangs
    /// off the composer's curve (the user, 2026-10-22); with one corner for both, that is none.
    public static let radius: CGFloat = DitherChrome.cardRadius
    public static let inset: CGFloat = DitherChrome.panelRadius - radius
    /// Between the composer and the first row, between rows, and between pills in a row.
    public static let gap: CGFloat = 8
    public static let spacing: CGFloat = 6

    /// The solid surface fill: a timeline card scrolled under a panel never reads through it (the user's 1.14.10
    /// subagent panel over the changed-files card, 2026-10-28).
    @MainActor public static func fill(in view: NSView) -> CGColor { RedesignTokens.Surface.fill(in: view) }

    /// The resting shadow.
    @MainActor public static func shadow(_ layer: CALayer, path: CGRect, radius: CGFloat, dark: Bool) {
        RedesignTokens.Shadow.resting.apply(to: layer, path: SmoothCorners.path(path, radius, flipped: false), dark: dark)
    }

    /// The motion for a pill that appears: up 4pt and in from clear, 150 ms on Capy's curve.
    @MainActor public static func animateIn(_ view: NSView) {
        guard !Motion.reduced, let layer = view.layer else { return }
        let rise = CABasicAnimation(keyPath: "transform.translation.y")
        rise.fromValue = RedesignTokens.Motion.rise
        rise.toValue = 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        for a in [rise, fade] {
            a.duration = RedesignTokens.Motion.quick
            a.timingFunction = curve
            layer.add(a, forKey: "pill.in." + a.keyPath!)
        }
    }

    @MainActor public static var curve: CAMediaTimingFunction { RedesignTokens.Motion.curve }
}

/// The pill chrome as a view, placed under a control that draws no surface of its own (the chips, the checkout and
/// branch controls). Lets clicks through.
public final class DitherPillSurface: DSView {
    public var radius: CGFloat = DitherPill.radius { didSet { if radius != oldValue { needsLayout = true } } }
    /// The panel's own ground instead of the raised surface, for a large surface whose cards must stand a step
    /// above it (Settings).
    public var ground = false { didSet { if ground != oldValue { needsDisplay = true } } }
    private let shade = DSView()
    private let face = DSView()

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.masksToBounds = false
        face.layer?.borderWidth = 1
        face.layer?.masksToBounds = true
        for v in [shade, face] { addSubview(v) }
        setAccessibilityElement(false)
        // Increase Contrast changes the rim.
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(displayOptionsChanged),
                                                          name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    @objc private func displayOptionsChanged(_ note: Notification) { needsDisplay = true }

    public override func updateLayer() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        face.layer?.backgroundColor = ground ? Themed.color(\.background).cgColor(in: self) : DitherPill.fill(in: self)
        face.layer?.borderColor = DitherChrome.rim(dark: effectiveAppearance.isDark).cgColor
        CATransaction.commit()
        needsLayout = true
    }

    public override func layout() {
        super.layout()
        let r = min(radius, bounds.height / 2)
        for v in [shade, face] { v.frame = bounds }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        face.layer?.cornerRadius = r
        shade.layer?.masksToBounds = false
        DitherPill.shadow(shade.layer!, path: shade.bounds, radius: r, dark: effectiveAppearance.isDark)
        shade.layer?.mask = DitherPill.outsideMask(shade.bounds, radius: r, existing: shade.layer?.mask)
        CATransaction.commit()
    }
}

extension DitherPill {
    /// Keeps a shadow outside its shape. The surface is opaque now, but a shadow under a 1pt translucent rim would
    /// still darken the rim.
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
