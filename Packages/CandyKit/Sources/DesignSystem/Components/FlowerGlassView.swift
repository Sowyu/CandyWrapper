import AppKit

/// What a surface floating over the Flower background shows under its fill (`RedesignTokens.FlowerGlass`): the panel's
/// ground, which hides whatever scrolls under the surface, and over it the flower blurred, lined up with the art behind.
/// A surface puts it under its fill, at its own frame and corner. Outside Flower, or under Reduce Transparency, it draws
/// nothing and the fill is solid. The blurred image is the art's (`DitherArtView`), one per window, shared by every
/// surface; nothing here redraws unless the surface moves or the art publishes a new one.
public final class FlowerGlassView: DSView {
    public var radius: CGFloat = 0 { didSet { if radius != oldValue { needsLayout = true } } }
    private let glow = CALayer()
    private let glowMask = CALayer()

    /// What the art in a window publishes: the blurred flower, where it sits in window coordinates, its ink and
    /// faintness, and whether the open flower shows (during a bloom only the ground does).
    struct Source {
        var image: CGImage
        var frame: CGRect
        var ink: CGColor
        var opacity: Float
        /// The image's brightest pixel, 0...1.
        var peak: Float
        var shown: Bool
    }

    @MainActor static let sources = NSMapTable<NSWindow, SourceBox>.weakToStrongObjects()
    @MainActor private static let views = NSHashTable<FlowerGlassView>.weakObjects()

    final class SourceBox { let source: Source; init(_ s: Source) { source = s } }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let still: [String: CAAction] = ["bounds": NSNull(), "position": NSNull(), "contents": NSNull(), "backgroundColor": NSNull(),
                                         "opacity": NSNull(), "hidden": NSNull(), "cornerRadius": NSNull()]
        layer?.actions = still
        layer?.masksToBounds = true
        glow.actions = still
        glowMask.actions = still
        glowMask.contentsGravity = .resize
        glowMask.magnificationFilter = .linear
        glow.mask = glowMask
        glow.isHidden = true
        layer?.addSublayer(glow)
        setAccessibilityElement(false)
        Self.views.add(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public override func hitTest(_ point: NSPoint) -> NSView? { nil }
    public override func updateLayer() { sync() }
    public override func layout() { super.layout(); sync() }
    public override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); sync() }

    /// The art in `window` published a new glow, or took it away.
    @MainActor static func publish(_ source: Source?, in window: NSWindow) {
        if let source { sources.setObject(SourceBox(source), forKey: window) } else { sources.removeObject(forKey: window) }
        for view in views.allObjects where view.window === window { view.sync() }
    }

    func sync() {
        let dark = effectiveAppearance.isDark
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        layer?.cornerRadius = min(radius, bounds.height / 2)
        guard let window, RedesignTokens.FlowerGlass.isOn(dark: dark) else {
            layer?.backgroundColor = nil
            glow.isHidden = true
            glowMask.contents = nil
            return
        }
        layer?.backgroundColor = ThemeRuntime.palettes.palette(dark: dark, sidebar: false).background.nsColor.cgColor
        guard let source = Self.sources.object(forKey: window)?.source, source.shown else {
            glow.isHidden = true
            return
        }
        glow.frame = convert(source.frame, from: nil)
        glowMask.frame = glow.bounds
        glowMask.contents = source.image
        let light = Self.light(source.ink)
        glow.backgroundColor = CGColor(srgbRed: light.x, green: light.y, blue: light.z, alpha: 1)
        // At its brightest the light under the glass leaves the surface's text its floors.
        let cap = Self.cap(light: light, dark: dark)
        glow.opacity = min(source.opacity, source.peak > 0 ? Float(cap) / source.peak : 1)
        glow.isHidden = false
    }

    var glowShownForTesting: Bool { !glow.isHidden && glowMask.contents != nil }
    var glowOpacityForTesting: Float { glow.opacity }

    /// The ink with its chroma lifted (`FlowerGlass.saturation`), so the light stays violet and not grey.
    static func light(_ ink: CGColor) -> SIMD3<Double> {
        let c = ink.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components ?? [0, 0, 0, 1]
        let o = PictureInk.oklch(srgb: SIMD3(Double(c[0]), Double(c[1]), Double(c[2])))
        let s = PictureInk.srgb(oklch: o.l, o.c * RedesignTokens.FlowerGlass.saturation, o.h)
        return SIMD3(min(max(s.x, 0), 1), min(max(s.y, 0), 1), min(max(s.z, 0), 1))
    }

    /// The most of the light (0...1) the glass may let through: the fill over the ground with the light at that share
    /// keeps body and muted text at `LotusArt.textFloors`.
    @MainActor static func cap(light: SIMD3<Double>, dark: Bool) -> Double {
        let p = ThemeRuntime.palettes.palette(dark: dark, sidebar: false)
        func rgb(_ c: TokenColor) -> SIMD3<Double> { let v = c.srgb; return SIMD3(v.x, v.y, v.z) }
        let fill = rgb(dark ? p.surfaceRaised : p.card), ground = rgb(p.background)
        let text = PictureInk.luminance(rgb(p.foreground)), muted = PictureInk.luminance(rgb(p.mutedForeground))
        let share = Double(RedesignTokens.FlowerGlass.fill), floors = LotusArt.textFloors(dark: dark)
        var best = 0.0
        for step in 0...100 {
            let a = Double(step) / 100
            let under = ground + (light - ground) * a
            let bg = PictureInk.luminance(fill * share + under * (1 - share))
            guard PictureInk.contrast(bg, text) >= floors.body, PictureInk.contrast(bg, muted) >= floors.muted else { break }
            best = a
        }
        return best
    }
}
