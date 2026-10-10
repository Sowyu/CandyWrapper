import AppKit

/// Dynamic theme colors with T3's opacity modifiers (`bg-primary/90` is the color at 90% alpha).
public enum Themed {
    /// A main-palette color, optionally at an alpha multiplier.
    public static func color(_ key: KeyPath<Palette, TokenColor>, _ alpha: Double = 1, sidebar: Bool = false) -> NSColor {
        let palette = sidebar ? ThemeColors.sidebar : ThemeColors.main
        return color(light: palette.light[keyPath: key], alpha, dark: palette.dark[keyPath: key], alpha)
    }

    /// Different tokens per theme, for `dark:` overrides such as `dark:bg-input/32`.
    public static func color(light: KeyPath<Palette, TokenColor>, _ lightAlpha: Double = 1,
                             dark: KeyPath<Palette, TokenColor>, _ darkAlpha: Double = 1) -> NSColor {
        color(light: Tokens.light[keyPath: light], lightAlpha, dark: Tokens.dark[keyPath: dark], darkAlpha)
    }

    static func color(light: TokenColor, _ lightAlpha: Double, dark: TokenColor, _ darkAlpha: Double) -> NSColor {
        let l = light.nsColor.multiplyingAlpha(lightAlpha)
        let d = dark.nsColor.multiplyingAlpha(darkAlpha)
        return NSColor(name: nil) { $0.isDark ? d : l }
    }

    /// Tailwind palette colors by name (`text-blue-600 dark:text-blue-400` is `base("blue-600", dark: "blue-400")`).
    public static func base(_ light: String, _ lightAlpha: Double = 1, dark: String? = nil, _ darkAlpha: Double? = nil) -> NSColor {
        color(light: Tokens.baseColors[light]!, lightAlpha, dark: Tokens.baseColors[dark ?? light]!, darkAlpha ?? lightAlpha)
    }

    /// Fixed colors such as `--color-white/16%` in arbitrary shadows.
    public static func white(_ alpha: Double) -> NSColor { NSColor(srgbRed: 1, green: 1, blue: 1, alpha: alpha) }
    public static func black(_ alpha: Double) -> NSColor { NSColor(srgbRed: 0, green: 0, blue: 0, alpha: alpha) }

    /// Same color in both themes.
    public static func same(_ color: NSColor) -> NSColor { color }

    /// Picks per theme from two already-dynamic or fixed colors.
    public static func pick(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.isDark ? dark : light }
    }
}

extension NSColor {
    func multiplyingAlpha(_ factor: Double) -> NSColor {
        factor == 1 ? self : withAlphaComponent(alphaComponent * factor)
    }
}
