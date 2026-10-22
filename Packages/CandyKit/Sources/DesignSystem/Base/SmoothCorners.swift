import AppKit
import ObjectiveC
import QuartzCore

/// Continuous ("squircle") corners for the Dither theme: Apple's `cornerCurve = .continuous` on layers and the same
/// curve for drawn paths, so a corner eases out of its straight edge instead of meeting it as a circular arc.
public enum SmoothCorners {
    /// How far the continuous curve reaches along each edge, as a multiple of the radius (Apple's continuous corner).
    static let reach: CGFloat = 1.528665

    /// The curve of one corner as (along the incoming edge back from the corner, along the outgoing edge) pairs in
    /// radius units: three cubics from the edge to the edge, after the curve UIKit draws for continuous corners.
    private static let segments: [(CGPoint, CGPoint, CGPoint)] = [
        (CGPoint(x: 1.088492, y: 0), CGPoint(x: 0.868407, y: 0), CGPoint(x: 0.631494, y: 0.074911)),
        (CGPoint(x: 0.372824, y: 0.169060), CGPoint(x: 0.169060, y: 0.372824), CGPoint(x: 0.074911, y: 0.631494)),
        (CGPoint(x: 0, y: 0.868407), CGPoint(x: 0, y: 1.088492), CGPoint(x: 0, y: reach)),
    ]

    /// A rect with `corners` (CSS sides) rounded by continuous curves. `flipped` says whether +y is down. A radius that
    /// reaches half the short side stays a circular pill; one whose curve wouldn't fit shrinks until it does.
    public static func path(_ rect: CGRect, _ radius: CGFloat, corners: BoxStyle.Corners = .all, flipped: Bool) -> CGPath {
        let half = min(rect.width, rect.height) / 2
        let r0 = max(0, min(radius, half))
        if r0 == 0 || r0 >= half {
            return BoxPainter.cornerRounded(rect, r0, corners: corners, flipped: flipped)
        }
        let r = min(r0, half / reach)
        let (top, bottom) = flipped ? (rect.minY, rect.maxY) : (rect.maxY, rect.minY)
        let points: [(CGPoint, BoxStyle.Corners)] = [
            (CGPoint(x: rect.maxX, y: top), .topRight), (CGPoint(x: rect.maxX, y: bottom), .bottomRight),
            (CGPoint(x: rect.minX, y: bottom), .bottomLeft), (CGPoint(x: rect.minX, y: top), .topLeft),
        ]
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.midX, y: top))
        for i in 0..<4 {
            let (c, corner) = points[i]
            guard corners.contains(corner) else { path.addLine(to: c); continue }
            let prev = points[(i + 3) % 4].0, next = points[(i + 1) % 4].0
            let back = unit(prev, c), out = unit(next, c)
            func at(_ p: CGPoint) -> CGPoint {
                CGPoint(x: c.x + (back.x * p.x + out.x * p.y) * r, y: c.y + (back.y * p.x + out.y * p.y) * r)
            }
            path.addLine(to: at(CGPoint(x: reach, y: 0)))
            for (c1, c2, end) in segments { path.addCurve(to: at(end), control1: at(c1), control2: at(c2)) }
        }
        path.closeSubpath()
        return path
    }

    /// The unit vector from `b` toward `a`.
    private static func unit(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        let dx = a.x - b.x, dy = a.y - b.y
        let len = max(hypot(dx, dy), .ulpOfOne)
        return CGPoint(x: dx / len, y: dy / len)
    }

    // MARK: Layers

    /// The key a layer carries once this gave it continuous corners, so turning Dither off hands back only those.
    private static let markKey = "cwSmoothCorners"
    nonisolated(unsafe) private static var installed = false

    /// Makes every layer that takes a corner radius while Dither shows use continuous corners. Installed the first
    /// time Dither turns on, so other themes never run it.
    /// ponytail: swaps `-[CALayer setCornerRadius:]` once for ~290 call sites; a per-site helper if a macOS release
    /// breaks the swap.
    @MainActor
    static func install() {
        guard !installed else { return }
        installed = true
        let cls: AnyClass = CALayer.self
        guard let original = class_getInstanceMethod(cls, #selector(setter: CALayer.cornerRadius)),
              let replacement = class_getInstanceMethod(cls, #selector(CALayer.cw_setCornerRadius(_:))) else { return }
        method_exchangeImplementations(original, replacement)
    }

    /// Whether a layer set now takes continuous corners: Dither in the app's appearance.
    static var active: Bool {
        let flags = (light: ThemeRuntime.isDither(dark: false), dark: ThemeRuntime.isDither(dark: true))
        if flags.light == flags.dark { return flags.light }
        guard Thread.isMainThread else { return flags.dark }
        return MainActor.assumeIsolated { ThemeRuntime.isDither(dark: NSApp?.effectiveAppearance.isDark ?? true) }
    }

    static func apply(to layer: CALayer, smooth: Bool) {
        if smooth, layer.cornerRadius > 0 {
            if layer.cornerCurve != .continuous { layer.cornerCurve = .continuous; layer.setValue(true, forKey: markKey) }
        } else if layer.cornerCurve == .continuous, layer.value(forKey: markKey) as? Bool == true {
            layer.cornerCurve = .circular
            layer.setValue(nil, forKey: markKey)
        }
    }

    /// Brings a layer tree's existing corners in line after the theme changed.
    static func sync(_ layer: CALayer, smooth: Bool) {
        apply(to: layer, smooth: smooth)
        for sub in layer.sublayers ?? [] { sync(sub, smooth: smooth) }
    }
}

extension CALayer {
    /// Swapped with `setCornerRadius:` by `SmoothCorners.install`, so this calls the original.
    @objc dynamic func cw_setCornerRadius(_ radius: CGFloat) {
        cw_setCornerRadius(radius)
        SmoothCorners.apply(to: self, smooth: SmoothCorners.active)
    }
}
