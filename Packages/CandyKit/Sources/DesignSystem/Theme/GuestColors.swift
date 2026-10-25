import AppKit

/// T3's guest colors (apps/web/src/index.css:1138-1141, 1193 at 3669): messages from a guest link and the
/// sidebar's Request status. `design/t3-source` still holds 3473's stylesheet, so the generated tokens lack them.
// ponytail: hand-copied from 3669's main.css; move into the generated tokens when design/t3-source reaches 3669
public enum GuestColors {
    /// `--color-fuchsia-300`, `oklch(83.3% .145 321.434)`, missing from 3473's palette.
    static let fuchsia300 = TokenColor(srgb: SIMD4(0.9551, 0.6573, 1.0071, 1), displayP3: SIMD4(0.9114, 0.6701, 0.9862, 1))

    /// `--guest`: fuchsia-500 in both themes.
    public static let guest = Themed.base("fuchsia-500")

    /// `--guest-foreground`: fuchsia-600, fuchsia-300 in dark.
    public static let foreground = Themed.color(light: Tokens.baseColors["fuchsia-600"]!, 1, dark: fuchsia300, 1)

    /// `--guest-surface`: `color-mix(in srgb, var(--guest) 14%, var(--message-surface))`, so it follows the theme's
    /// message surface.
    public static let surface: NSColor = NSColor(name: nil) { appearance in
        let base = ThemeRuntime.palettes.palette(dark: appearance.isDark, sidebar: false).messageSurface
        let c = mix(Tokens.baseColors["fuchsia-500"]!.srgb, 0.14, base.srgb)
        return NSColor(colorSpace: .extendedSRGB, components: [c.x, c.y, c.z, c.w].map { CGFloat($0) }, count: 4)
    }

    /// `color-mix(in srgb, a p, b)`, premultiplied as CSS mixes colors with alpha.
    static func mix(_ x: SIMD4<Double>, _ p: Double, _ y: SIMD4<Double>) -> SIMD4<Double> {
        let alpha = x.w * p + y.w * (1 - p)
        guard alpha > 0 else { return .zero }
        let rgb = (SIMD3(x.x, x.y, x.z) * x.w * p + SIMD3(y.x, y.y, y.z) * y.w * (1 - p)) / alpha
        return SIMD4(rgb.x, rgb.y, rgb.z, alpha)
    }
}
