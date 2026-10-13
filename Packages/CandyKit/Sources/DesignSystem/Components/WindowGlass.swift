import AppKit

/// CandyWrapper's Glass theme (not in T3): the stock palette over a window the system frosts. A behind-window
/// `NSVisualEffectView` under the whole layout does the blur in the window server, so the app never computes
/// it and nothing here redraws when the desktop behind changes. The base surfaces (main panel and sidebar)
/// paint their stock color at `alpha`, and views that repeat the main background over them go clear, so one
/// tint covers the blur everywhere. Popovers, menus and dialogs keep their own fills.
public enum WindowGlass {
    /// How much of a base surface's own color covers the blur. Glass keeps 60% at T3's default "Glass opacity" of
    /// 80% (index.css:117), so the frost shows; the setting scales it (7.5% at 10%, 75% at 100%). T3's own glass
    /// surfaces keep using the setting unchanged.
    public static var alpha: CGFloat { 0.75 * ThemeRuntime.glassOpacity }

    /// The muted text Glass wears so it reads at 4.5:1 or better over its frost on a busy or plain desktop: no
    /// lighter (light) or darker (dark) than these. Measured at the default opacity over a striped worst case.
    nonisolated static let mutedLight = ThemeCSSColor.parse("#6b6b74")!.token
    nonisolated static let mutedDark = ThemeCSSColor.parse("#959595")!.token
    nonisolated static let mutedMembers: Set<String> = ["--muted-foreground", "--contrast-muted-foreground", "--sidebar-muted-foreground",
                                                       "--contrast-sidebar-muted-foreground", "--icon-muted", "--contrast-icon-muted"]

    /// The readable muted color at a "Glass opacity" (0.1...1). From the default 80% up it is the measured color.
    /// Below, the surface lets more of the frost through, so the color moves away from the background until it
    /// keeps 4.5:1 against a modeled worst case: `alpha` of the stock background over a frost whose luminance
    /// is solved so the measured color sits at exactly 4.5:1 at 80%.
    nonisolated static func readableMutedTarget(dark: Bool, opacity: Double) -> TokenColor {
        let base = dark ? mutedDark : mutedLight
        let alpha = 0.75 * min(max(opacity, 0.1), 1)
        let tuned = 0.75 * 0.8
        guard alpha < tuned else { return base }
        let lText = luminance(base), lStock = luminance(dark ? Tokens.dark.background : Tokens.light.background)
        let backgroundAtTuned = dark ? (lText + 0.05) / 4.5 - 0.05 : 4.5 * (lText + 0.05) - 0.05
        let frost = (backgroundAtTuned - tuned * lStock) / (1 - tuned)
        let background = alpha * lStock + (1 - alpha) * frost
        let lin = SIMD3(linear(base.srgb.x), linear(base.srgb.y), linear(base.srgb.z))
        let out: SIMD3<Double>
        if dark {
            // Toward white: luminance is linear in linear light, so one mix factor reaches the target.
            let target = min(1, 4.5 * (background + 0.05) - 0.05)
            let t = max(0, (target - lText) / (1 - lText))
            out = lin + (SIMD3(repeating: 1) - lin) * t
        } else {
            let target = max(0, (background + 0.05) / 4.5 - 0.05)
            out = lin * min(1, target / lText)
        }
        return ThemeCSSColor(srgb: gamma(out.x), gamma(out.y), gamma(out.z)).token
    }

    nonisolated static func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    nonisolated static func gamma(_ c: Double) -> Double { c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055 }
    /// WCAG relative luminance.
    nonisolated static func luminance(_ c: TokenColor) -> Double {
        0.2126 * linear(c.srgb.x) + 0.7152 * linear(c.srgb.y) + 0.0722 * linear(c.srgb.z)
    }

    /// `palette` with its muted text moved to Glass's readable muted color where the stock one is fainter.
    nonisolated static func readableMuted(_ palette: Palette, dark: Bool, opacity: Double = 0.8) -> Palette {
        let target = readableMutedTarget(dark: dark, opacity: opacity)
        func lum(_ c: TokenColor) -> Double { 0.2126 * c.srgb.x + 0.7152 * c.srgb.y + 0.0722 * c.srgb.z }
        let members = palette.members
        return Palette(members: { i in
            let c = members[i]
            guard mutedMembers.contains(Palette.memberNames[i]) else { return c }
            return dark ? (lum(c) < lum(target) ? target : c) : (lum(c) > lum(target) ? target : c)
        })
    }

    /// A base surface's fill: the token, at `alpha` while Glass frosts the window in that appearance.
    public static func surface(_ key: KeyPath<Palette, TokenColor>, sidebar: Bool = false) -> NSColor {
        NSColor(name: nil) { appearance in
            let dark = appearance.isDark
            let color = ThemeRuntime.palettes.palette(dark: dark, sidebar: sidebar)[keyPath: key].nsColor
            return ThemeRuntime.isGlass(dark: dark) ? color.withAlphaComponent(alpha) : color
        }
    }

    /// The main background painted again over the main surface (right panel, empty states): clear while frosted,
    /// so the right panel shows the same frost as the thread beside it.
    public static let inset = NSColor(name: nil) { appearance in
        let dark = appearance.isDark
        return ThemeRuntime.isGlass(dark: dark) ? .clear : ThemeRuntime.palettes.palette(dark: dark, sidebar: false).background.nsColor
    }

    public static let mainSurface = surface(\.background)
    public static let sidebarSurface = surface(\.sidebar, sidebar: true)

    /// Whether Glass frosts `view`'s window in the view's appearance.
    @MainActor
    public static func isActive(for view: NSView) -> Bool { ThemeRuntime.isGlass(dark: view.effectiveAppearance.isDark) }

    /// Puts the frost under `view`'s subviews while Glass frosts its window and takes it out otherwise. Pass the
    /// backdrop it returned last time.
    @MainActor
    public static func syncBackdrop(_ backdrop: WindowGlassBackdropView?, in view: NSView) -> WindowGlassBackdropView? {
        let on = view.window != nil && isActive(for: view)
        if on, backdrop == nil {
            let made = WindowGlassBackdropView(frame: view.bounds)
            view.addSubview(made, positioned: .below, relativeTo: nil)
            return made
        }
        if !on, let backdrop {
            backdrop.removeFromSuperview()
            return nil
        }
        return backdrop
    }
}

/// The frost itself: a behind-window visual effect view that keeps the system's material and blur but paints
/// nothing of its own on top. The window server composites it; it has no backing store in this process.
public final class WindowGlassBackdropView: NSVisualEffectView {
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        blendingMode = .behindWindow
        material = .underWindowBackground
        // Inactive windows fall back to the flat material like every Mac sidebar, so a background window
        // costs the compositor nothing extra.
        state = .followsWindowActiveState
        autoresizingMask = [.width, .height]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // Clicks belong to the surfaces above.
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }
    public override func isAccessibilityElement() -> Bool { false }
}
