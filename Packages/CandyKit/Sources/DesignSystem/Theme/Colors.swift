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

    /// Text on a solid token fill that T3 paints `text-white` (`bg-destructive text-white`). It stays white while
    /// white reads at 3:1 or better, so the stock palettes match T3, and turns near-black when a theme's fill is too
    /// pale for white.
    public static func textOn(_ key: KeyPath<Palette, TokenColor>) -> NSColor {
        let wrapped = TextOnKey(key: key)
        return instancesLock.withLock {
            if let color = textOnInstances[wrapped] { return color }
            let color = NSColor(name: nil) { appearance in
                let fill = ThemeRuntime.palettes.palette(dark: appearance.isDark, sidebar: false)[keyPath: key]
                return readsWhite(on: fill) ? white(1) : darkText
            }
            textOnInstances[wrapped] = color
            return color
        }
    }
    nonisolated(unsafe) private static var textOnInstances: [TextOnKey: NSColor] = [:]
    private static let darkText = NSColor(srgbRed: 0.09, green: 0.09, blue: 0.11, alpha: 1)

    /// Whether white text keeps WCAG's 3:1 for large and bold UI text on `fill`.
    nonisolated static func readsWhite(on fill: TokenColor) -> Bool {
        1.05 / (WindowGlass.luminance(fill) + 0.05) >= 3
    }

    /// Same color in both themes.
    public static func same(_ color: NSColor) -> NSColor { color }

    /// Picks per theme from two already-dynamic or fixed colors.
    public static func pick(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.isDark ? dark : light }
    }
}

private struct TextOnKey: Hashable, @unchecked Sendable {
    let key: KeyPath<Palette, TokenColor>
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
        let key = isDark ? dark : light
        var alpha = isDark ? darkAlpha : lightAlpha
        // Classic Glass: T3's faint muted text (`text-muted-foreground/70`, a branch at `/40`) reads at full strength, since the
        // frost already pushed muted text as far toward the background as 4.5:1 allows (WindowGlass.frostReadable).
        if alpha >= 0.35, alpha < 1, ThemeRuntime.isGlass(dark: isDark), WindowGlass.frostFullStrength.contains(key) { alpha = 1 }
        let c = palette[keyPath: key].nsColor.multiplyingAlpha(alpha)
        if isDark { darkColor = c } else { lightColor = c }
        return c
    }
}

extension NSColor {
    func multiplyingAlpha(_ factor: Double) -> NSColor {
        factor == 1 ? self : withAlphaComponent(alphaComponent * factor)
    }
}

/// Find in thread's match paint (index.css:376-394): the theme's `--app-theme-search-match-*` colors, else T3's
/// fallbacks. The compiled stylesheet turns the fallbacks' `@variant dark` block into `:is()`, which never
/// matches, so the stock look paints the light colors in both appearances (design/reference/43-find-in-thread).
@MainActor
public enum SearchMatchColors {
    public static func background(active: Bool, dark: Bool) -> NSColor {
        color(active ? .searchMatchActiveBackground : .searchMatchBackground, dark: dark,
              fallback: active ? activeBackground : background)
    }

    public static func foreground(active: Bool, dark: Bool) -> NSColor {
        color(active ? .searchMatchActiveForeground : .searchMatchForeground, dark: dark, fallback: foreground)
    }

    private static func color(_ role: ThemeColorRole, dark: Bool, fallback: NSColor) -> NSColor {
        let half = dark ? ThemeRuntime.input.dark : ThemeRuntime.input.light
        return half?.colors[role].flatMap(ThemeCSSColor.parse)?.token.nsColor ?? fallback
    }

    private static let background = ThemeCSSColor.parse("oklch(91.5% .11 85)")!.token.nsColor
    private static let activeBackground = ThemeCSSColor.parse("oklch(77.4202% .151946 74.331)")!.token.nsColor
    private static let foreground = ThemeCSSColor.parse("oklch(21.6164% .028283 77.423)")!.token.nsColor
}
