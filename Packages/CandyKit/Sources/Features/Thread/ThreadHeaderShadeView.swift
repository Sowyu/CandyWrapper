import AppKit
import DesignSystem

/// Redesign: what lies over a thread's rows where they slide up under the header (the user, 2026-11-22: "go back to
/// stuff being allowed to render under here with just under that text have a blur and a black fade from the top
/// down"). The rows run to the window's top edge; over them a backdrop blur, strongest at the top and eased to none,
/// and a wash of the band's color, dark in dark and the light ground in light, from the top edge down to nothing a
/// little below the header row. It rebuilds the Glass header of 1.10 (`topBlur` and `GlassHeaderTint`, removed in
/// 324b6bcf) with public API: an `NSVisualEffectView` blending within the window, its material's tint layers hidden
/// and its strength falling off through `maskImage`. Under Reduce Transparency there is no blur and the wash is a
/// taller solid-to-clear fade.
///
/// The blur is the window server's: it costs only while what lies under it changes (scrolling, streaming) and
/// nothing while the thread sits still. Offscreen snapshots draw only the wash.
final class ThreadHeaderShadeView: DSView {
    /// How far below the band the shade reaches, and the taller reach without the blur.
    static let reach: CGFloat = 28
    static let solidReach: CGFloat = 48
    /// The wash's opacity at the window's top edge.
    static let washTop: Double = 0.94

    private let blur = HeaderBlurView()
    private let wash = CAGradientLayer()
    private var maskHeight: CGFloat = 0
    private var solid: Bool?

    /// The height to give the view: the band plus the reach.
    static func height(reducesTransparency: Bool) -> CGFloat { DitherChrome.band + (reducesTransparency ? solidReach : reach) }

    /// Smoothstep from 0 at `t = 0` to 1 at `t = 1`.
    private static func ease(_ t: Double) -> Double { let x = min(1, max(0, t)); return x * x * (3 - 2 * x) }

    /// The wash's opacity at `t`, 0 at the top edge to 1 at the shade's bottom.
    static func wash(_ t: Double, solid: Bool) -> Double {
        // Without the blur the breadcrumb's row stays fully covered, then the wash eases out.
        // With it, the wash holds over the breadcrumb's row, so the title reads over the rows, then eases out.
        solid ? 1 - ease((t - 0.4) / 0.6) : washTop * (1 - ease((t - 0.3) / 0.7))
    }

    /// The blur's strength at `t`: all of it over the breadcrumb's row, then easing to none at 85%, before the wash
    /// ends. The mask cross-fades the blurred copy with the sharp rows under it, so a partly blurred row still reads
    /// sharp: the blur stays whole where the rows must go soft.
    static func blurStrength(_ t: Double) -> Double { 1 - ease((t - 0.35) / 0.5) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(blur)
        wash.actions = ["bounds": NSNull(), "position": NSNull(), "colors": NSNull(), "locations": NSNull()]
        layer?.addSublayer(wash)
        setAccessibilityElement(false)
        // Reduce Transparency and "Ignore Reduce Transparency" swap the blur for the solid fade.
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

    override func layout() {
        super.layout()
        let solid = ThemeRuntime.reducesTransparency()
        blur.isHidden = solid
        blur.frame = bounds
        CATransaction.begin(); CATransaction.setDisableActions(true)
        wash.frame = bounds
        CATransaction.commit()
        if blur.maskImage == nil || maskHeight != bounds.height {
            maskHeight = bounds.height
            blur.maskImage = Self.mask(height: bounds.height)
        }
        if solid != self.solid { self.solid = solid; needsDisplay = true }
    }

    override func updateLayer() {
        super.updateLayer()
        let band = DitherChrome.bandColor(in: self), solid = ThemeRuntime.reducesTransparency()
        let ts = (0...12).map { Double($0) / 12 }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        wash.locations = ts.map { NSNumber(value: $0) }
        wash.colors = ts.map { band.copy(alpha: Self.wash($0, solid: solid))! }
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

    /// One column of alpha, stretched across the width: the blur's strength from the top down.
    private static func mask(height: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: 1, height: max(1, height)), flipped: true) { rect in
            let steps = 24
            for i in 0..<steps {
                let t = Double(i) / Double(steps - 1)
                NSColor.black.withAlphaComponent(blurStrength(t)).setFill()
                NSRect(x: 0, y: rect.height * CGFloat(i) / CGFloat(steps), width: 1, height: rect.height / CGFloat(steps) + 0.5).fill()
            }
            return true
        }
        image.capInsets = NSEdgeInsetsZero
        image.resizingMode = .stretch
        return image
    }
}

/// The system backdrop blur inside the window with the material's color layers hidden, so the ground shows through
/// in its own color. Public API only: the radius is the material's, the strength comes from `maskImage`.
// ponytail: hides the effect view's non-backdrop sublayers by class name; if a macOS update renames them the material
// tints the shade, revisit on each new macOS.
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
