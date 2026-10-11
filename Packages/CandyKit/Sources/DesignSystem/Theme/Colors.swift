import AppKit

/// Dynamic theme colors with T3's opacity modifiers (`bg-primary/90` is the color at 90% alpha).
public enum Themed {
    /// A main-palette color, optionally at an alpha multiplier. It follows the window's appearance and
    /// `ThemeRuntime`'s palettes.
    public static func color(_ key: KeyPath<Palette, TokenColor>, _ alpha: Double = 1, sidebar: Bool = false) -> NSColor {
        runtime(light: key, alpha, dark: key, alpha, sidebar: sidebar)
    }

    /// Different tokens per theme, for `dark:` overrides such as `dark:bg-input/32`.
    public static func color(light: KeyPath<Palette, TokenColor>, _ lightAlpha: Double = 1,
                             dark: KeyPath<Palette, TokenColor>, _ darkAlpha: Double = 1) -> NSColor {
        runtime(light: light, lightAlpha, dark: dark, darkAlpha, sidebar: false)
    }

    /// Resolves from the runtime palettes, remembering the result until the theme changes, so a draw
    /// costs what a fixed color costs.
    private static func runtime(light: KeyPath<Palette, TokenColor>, _ lightAlpha: Double, dark: KeyPath<Palette, TokenColor>,
                                _ darkAlpha: Double, sidebar: Bool) -> NSColor {
        // One instance per token and alpha, so views that skip unchanged colors see equal values
        // (an unnamed dynamic NSColor equals only itself) and don't redraw on every reconfigure.
        let key = ThemedColorKey(light: light, lightAlpha: lightAlpha, dark: dark, darkAlpha: darkAlpha, sidebar: sidebar)
        return instancesLock.withLock {
            if let color = instances[key] { return color }
            let cache = ThemedColorCache(light: light, lightAlpha: lightAlpha, dark: dark, darkAlpha: darkAlpha, sidebar: sidebar)
            let color = NSColor(name: nil) { cache.color(dark: $0.isDark) }
            instances[key] = color
            return color
        }
    }
    nonisolated(unsafe) private static var instances: [ThemedColorKey: NSColor] = [:]
    private static let instancesLock = NSLock()

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

private struct ThemedColorKey: Hashable, @unchecked Sendable {
    let light: KeyPath<Palette, TokenColor>, lightAlpha: Double
    let dark: KeyPath<Palette, TokenColor>, darkAlpha: Double
    let sidebar: Bool
}

/// One `Themed` color's resolved values for the current `ThemeRuntime.generation`. Color providers run
/// on the main thread while drawing, which is also where the theme changes.
private final class ThemedColorCache: @unchecked Sendable {
    nonisolated(unsafe) let light: KeyPath<Palette, TokenColor>
    nonisolated(unsafe) let dark: KeyPath<Palette, TokenColor>
    let lightAlpha: Double, darkAlpha: Double, sidebar: Bool
    private var generation = -1
    private var lightColor: NSColor?, darkColor: NSColor?
    /// One instance serves every view using the token, and AppKit may resolve a color off the main thread.
    private let lock = NSLock()

    init(light: KeyPath<Palette, TokenColor>, lightAlpha: Double, dark: KeyPath<Palette, TokenColor>, darkAlpha: Double, sidebar: Bool) {
        self.light = light; self.lightAlpha = lightAlpha; self.dark = dark; self.darkAlpha = darkAlpha; self.sidebar = sidebar
    }

    func color(dark isDark: Bool) -> NSColor {
        lock.lock(); defer { lock.unlock() }
        let current = ThemeRuntime.generation
        if generation != current { generation = current; lightColor = nil; darkColor = nil }
        if let c = isDark ? darkColor : lightColor { return c }
        let palette = ThemeRuntime.palettes.palette(dark: isDark, sidebar: sidebar)
        let c = palette[keyPath: isDark ? dark : light].nsColor.multiplyingAlpha(isDark ? darkAlpha : lightAlpha)
        if isDark { darkColor = c } else { lightColor = c }
        return c
    }
}

extension NSColor {
    func multiplyingAlpha(_ factor: Double) -> NSColor {
        factor == 1 ? self : withAlphaComponent(alphaComponent * factor)
    }
}
