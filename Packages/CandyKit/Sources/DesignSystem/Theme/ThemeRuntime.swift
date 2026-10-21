import AppKit

/// The four palettes the app draws with: the main surface and the sidebar subtree, light and dark.
public struct ThemePalettes: Sendable {
    public let light: Palette
    public let dark: Palette
    public let sidebarLight: Palette
    public let sidebarDark: Palette

    public func palette(dark: Bool, sidebar: Bool) -> Palette {
        sidebar ? (dark ? sidebarDark : sidebarLight) : (dark ? self.dark : light)
    }

    /// T3's stock look, exactly as extracted (no evaluation).
    public static let standard = ThemePalettes(light: Tokens.light, dark: Tokens.dark,
                                               sidebarLight: Tokens.sidebarLight, sidebarDark: Tokens.sidebarDark)

    func isSame(as other: ThemePalettes) -> Bool {
        light.members == other.light.members && dark.members == other.dark.members
            && sidebarLight.members == other.sidebarLight.members && sidebarDark.members == other.sidebarDark.members
    }
}

/// What one appearance wears: a theme's role colors (canonical CSS, keyed by role), or nil for T3's stock look.
public struct ThemeRuntimeHalf: Equatable, Sendable {
    public var colors: [ThemeColorRole: String]
    /// A built-in theme id, whose own CSS blocks change a few tokens (the sidebar artwork).
    public var builtInId: String?

    public init(colors: [ThemeColorRole: String], builtInId: String? = nil) {
        self.colors = colors
        self.builtInId = builtInId
    }
}

/// Everything that decides the palettes: T3's `applyThemePalette` (themePalette.ts:1540-1563) per appearance,
/// `applyThemeColorPreview` for the editor's draft (1524-1538) and `applyAppearanceContrast`
/// (appearanceContrast.ts). `glassOpacity` is the `--glass-opacity` setting (__root.tsx:291-301).
public struct ThemeRuntimeInput: Equatable, Sendable {
    public var light: ThemeRuntimeHalf?
    public var dark: ThemeRuntimeHalf?
    public var contrast: Int
    public var glassOpacity: Int
    public var blueOrangeDiff = false
    /// CandyWrapper's Glass theme on each side: stock colors over a frosted window, every surface a frosted pane
    /// (`WindowGlass`).
    public var glassLight = false
    public var glassDark = false
    /// The Dither theme on each side and its picture (nil for the desktop picture).
    public var ditherLight = false
    public var ditherDark = false
    public var ditherPicture: String?

    public init(light: ThemeRuntimeHalf? = nil, dark: ThemeRuntimeHalf? = nil, contrast: Int = 100, glassOpacity: Int = 80) {
        self.light = light; self.dark = dark; self.contrast = contrast; self.glassOpacity = glassOpacity
    }
}

/// Runtime override of the generated tokens. T3 themes by setting `--app-theme-*` variables on `<html>`; every
/// semantic token is a CSS expression of those (extracted into `ThemeExpressions` by scripts/extract-tokens).
/// `apply` evaluates the expressions once per change into four palettes; `Themed` colors read them when AppKit
/// resolves a color, so drawing costs nothing extra and nothing runs while idle. A change that leaves the
/// palettes as they were redraws nothing; one that changes them tells each view as an appearance change does.
@MainActor
public enum ThemeRuntime {
    /// Read from color providers during drawing, written only on the main thread by `apply`.
    nonisolated(unsafe) public private(set) static var palettes = ThemePalettes.standard
    /// Bumped whenever `palettes` changes; cached colors compare against it.
    nonisolated(unsafe) public private(set) static var generation = 0
    /// `--glass-opacity` as a fraction (0.1...1; T3 stops at 0.4).
    nonisolated(unsafe) public private(set) static var glassOpacity: CGFloat = 0.8
    public private(set) static var input = ThemeRuntimeInput()
    /// Whether the Glass theme frosts the window in each appearance.
    nonisolated(unsafe) public private(set) static var glass = (light: false, dark: false)

    public nonisolated static func isGlass(dark: Bool) -> Bool { dark ? glass.dark : glass.light }
    /// Whether the main panel shows the Dither theme's picture in each appearance (`DitherArtView`).
    public private(set) static var dither = (light: false, dark: false)
    public private(set) static var ditherPicture: URL?
    public nonisolated static func isDither(dark: Bool) -> Bool { dark ? ditherFlags.dark : ditherFlags.light }
    // ponytail: one row style for both appearances, so a light theme paired with dark Dither shows Capy rows in light
    // too; pass the appearance to item heights if mixed setups matter.
    /// Whether the sidebar uses Dither's compact two-line rows: Dither on either side.
    public nonisolated static var ditherRows: Bool { ditherFlags.dark || ditherFlags.light }
    /// Whether floating panes and bubbles are frosted glass over their own blur: Glass and Dither.
    public nonisolated static func framesPanes(dark: Bool) -> Bool {
        isGlass(dark: dark) || (dark ? ditherFlags.dark : ditherFlags.light)
    }
    nonisolated(unsafe) private static var ditherFlags = (light: false, dark: false)

    /// Posted after `apply` changed something, for views that cache theme-derived values outside drawing.
    public static let didChange = Notification.Name("CandyThemeRuntimeDidChange")

    public static func apply(_ next: ThemeRuntimeInput) {
        guard next != input else { return }
        let old = input
        input = next
        var changed = false
        if next.light != old.light || next.dark != old.dark || next.contrast != old.contrast || next.blueOrangeDiff != old.blueOrangeDiff
            || next.glassLight != old.glassLight || next.glassDark != old.glassDark
            || next.ditherLight != old.ditherLight || next.ditherDark != old.ditherDark
            || (next.glassOpacity != old.glassOpacity && (next.glassLight || next.glassDark || next.ditherLight || next.ditherDark)) {
            let resolved = resolve(next)
            if !resolved.isSame(as: palettes) {
                palettes = resolved
                changed = true
            }
        }
        if next.glassOpacity != old.glassOpacity {
            glassOpacity = CGFloat(min(max(next.glassOpacity, 10), 100)) / 100
            changed = true
        }
        if next.glassLight != old.glassLight || next.glassDark != old.glassDark {
            glass = (next.glassLight, next.glassDark)
            changed = true
        }
        if next.ditherLight != old.ditherLight || next.ditherDark != old.ditherDark || next.ditherPicture != old.ditherPicture {
            dither = (next.ditherLight, next.ditherDark)
            ditherFlags = dither
            ditherPicture = next.ditherPicture.map { URL(filePath: $0) }
            changed = true
        }
        guard changed else { return }
        generation += 1
        for window in NSApp?.windows ?? [] {
            if let view = window.contentView?.superview ?? window.contentView { refresh(view) }
        }
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// Tells every view in the tree its colors changed, the same way AppKit tells them about light and dark.
    static func refresh(_ view: NSView) {
        view.viewDidChangeEffectiveAppearance()
        view.needsDisplay = true
        view.layer.map(redrawDecorations)
        for sub in view.subviews { refresh(sub) }
    }

    /// Redraws the box decorations in a view tree, for an appearance change AppKit doesn't pass on to them.
    public static func redrawDecorations(in view: NSView) {
        view.layer.map(redrawDecorations)
        for sub in view.subviews { redrawDecorations(in: sub) }
    }

    /// Box decorations keep their style when the colors behind it change, so they redraw here.
    private static func redrawDecorations(_ layer: CALayer) {
        for sub in layer.sublayers ?? [] where sub is ThemeRedrawingLayer { sub.setNeedsDisplay() }
    }

    /// The palettes for an input, without applying them.
    public nonisolated static func resolve(_ input: ThemeRuntimeInput) -> ThemePalettes {
        // The stock palettes at stock contrast are the extracted tokens themselves.
        let stock = input.contrast == 100
        let light = input.light == nil && stock ? nil : evaluate(input.light, contrast: input.contrast, contexts: (0, 2))
        let dark = input.dark == nil && stock ? nil : evaluate(input.dark, contrast: input.contrast, contexts: (1, 3))
        func diff(_ palette: Palette, dark: Bool) -> Palette {
            guard input.blueOrangeDiff else { return palette }
            // index.css:2086-2099 and the bundled Tailwind theme colors.
            let addition = ThemeCSSColor.parse(dark ? "oklch(70.7% .165 254.624)" : "oklch(54.6% .245 262.881)")!.token
            let deletion = ThemeCSSColor.parse(dark ? "oklch(75% .183 55.934)" : "oklch(64.6% .222 41.116)")!.token
            let members = palette.members
            return Palette(members: { i in
                switch Palette.memberNames[i] {
                case "--diff-addition", "--diff-addition-foreground": return addition
                case "--diff-deletion", "--diff-deletion-foreground": return deletion
                default: return members[i]
                }
            })
        }
        func glass(_ palette: Palette, dark: Bool, sidebar: Bool) -> Palette {
            // Dither: the main panel's cards, bubbles and popovers become frosted panes over its art. The sidebar and
            // the panel's own background stay solid.
            if !sidebar, dark ? input.ditherDark : input.ditherLight {
                return WindowGlass.frosted(palette, dark: dark, sidebar: false, opacity: Double(input.glassOpacity) / 100)
            }
            guard dark ? input.glassDark : input.glassLight else { return palette }
            let opacity = Double(input.glassOpacity) / 100
            let readable = WindowGlass.frostReadable(palette, dark: dark, sidebar: sidebar, opacity: opacity)
            return WindowGlass.frosted(readable, dark: dark, sidebar: sidebar, opacity: opacity)
        }
        return ThemePalettes(light: glass(diff(light?.0 ?? Tokens.light, dark: false), dark: false, sidebar: false),
                             dark: glass(diff(dark?.0 ?? Tokens.dark, dark: true), dark: true, sidebar: false),
                             sidebarLight: glass(diff(light?.1 ?? Tokens.sidebarLight, dark: false), dark: false, sidebar: true),
                             sidebarDark: glass(diff(dark?.1 ?? Tokens.sidebarDark, dark: true), dark: true, sidebar: true))
    }

    private nonisolated static let parsedStandard = ThemeExpressions.standard.map { $0.map(parse) }
    private nonisolated static let parsedThemed = ThemeExpressions.themed.map { $0.map(parse) }
    private nonisolated static let parsedBuiltIn = ThemeExpressions.builtIn.mapValues { $0.mapValues { $0.map(parse) } }

    private nonisolated static func parse(_ css: String) -> ThemeCSSExpression {
        ThemeCSSExpression.parse(css) ?? .literal(.transparent)
    }

    /// The main and sidebar palettes for one appearance (`contexts` index the expression columns).
    nonisolated static func evaluate(_ half: ThemeRuntimeHalf?, contrast: Int, contexts: (Int, Int)) -> (Palette, Palette) {
        let percents = [
            "--appearance-contrast-base": Double(min(contrast, 100)),
            "--appearance-contrast-boost": Double(max(contrast - 100, 0)),
            "--appearance-contrast-border-boost": Double(max(contrast - 100, 0)) / 4,
        ]
        var colors: [String: ThemeCSSColor] = [:]
        for (role, value) in half?.colors ?? [:] { colors[role.cssVariable] = ThemeCSSColor.parse(value) }
        let table = half == nil ? parsedStandard : parsedThemed
        let builtIn = half?.builtInId.flatMap { parsedBuiltIn[$0] } ?? [:]
        func palette(_ column: Int) -> Palette {
            Palette(members: { i in
                (builtIn[i]?[column] ?? table[i][column]).evaluate(colors: colors, percents: percents).token
            })
        }
        return (palette(contexts.0), palette(contexts.1))
    }
}

public extension ThemeCSSColor {
    /// The color in Display P3, as the design system draws tokens.
    var nsColor: NSColor { token.nsColor }

    /// A literal CSS color as an NSColor, or nil when it does not parse.
    static func nsColor(_ css: String) -> NSColor? { parse(css)?.nsColor }
}

/// Layers that paint theme colors into their contents and must redraw when the theme changes.
public protocol ThemeRedrawingLayer: CALayer {}
extension BoxDecorationLayer: ThemeRedrawingLayer {}
extension PopupShadowLayer: ThemeRedrawingLayer {}
