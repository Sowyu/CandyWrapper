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
    /// Redesign on each side. Its background is Gradient, the only one since 2026-11-27 (`DitherArtView`).
    public var ditherLight = false
    public var ditherDark = false
    /// Gradient's motion (the "Animate background" setting, stored as `redesignGradientAnimate`).
    public var ditherGradientAnimates = true
    /// Redesign's accent, a `DitherAccent` id.
    public var ditherAccent = DitherAccent.teal.id
    /// Redesign's "Project avatars": pixel sprites (on) or T3's letters.
    public var projectSprites = true
    /// Redesign's "Inset panel": the content is one rounded card inset from the window (`SidebarLayoutView`). The
    /// setting defaults on; this input stays off unless `ThemeLibrary` passes the setting, so tests and fixtures draw
    /// the full-bleed layout unless they ask for the card.
    public var insetPanel = false

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
    /// The "Animate background" setting, for Gradient (`DitherArtView`).
    nonisolated(unsafe) public private(set) static var ditherGradientAnimates = true
    /// Redesign's accent (the "Accent color" setting). Its palette roles arrive through the Dither half's colors.
    nonisolated(unsafe) public private(set) static var ditherAccent = DitherAccent.teal
    public private(set) static var input = ThemeRuntimeInput()

    /// Whether Redesign shows in each appearance, with Gradient in its main panel (`DitherArtView`).
    public private(set) static var dither = (light: false, dark: false)
    public nonisolated static func isDither(dark: Bool) -> Bool { dark ? ditherFlags.dark : ditherFlags.light }
    nonisolated(unsafe) private static var ditherFlags = (light: false, dark: false)
    /// This app's name where copy means the client: CandyWrapper under Redesign. The default themes keep T3's wording,
    /// which their fidelity tests pin.
    public nonisolated static func appName(dark: Bool) -> String { isDither(dark: dark) ? "CandyWrapper" : "T3 Code" }
    /// Whether project and account avatars without a picture draw `PixelSprites`: Redesign with "Project avatars" on Sprites.
    public nonisolated static func drawsSprites(dark: Bool) -> Bool { isDither(dark: dark) && spritesOn }
    nonisolated(unsafe) private static var spritesOn = true
    /// Whether the content is Redesign's inset card: Redesign with "Inset panel" on.
    public nonisolated static func insetPanel(dark: Bool) -> Bool { isDither(dark: dark) && insetOn }
    nonisolated(unsafe) private static var insetOn = false

    /// Posted after `apply` changed something, for views that cache theme-derived values outside drawing.
    public static let didChange = Notification.Name("CandyThemeRuntimeDidChange")

    public static func apply(_ next: ThemeRuntimeInput) {
        guard next != input else { return }
        let old = input
        input = next
        var changed = false
        if next.light != old.light || next.dark != old.dark || next.contrast != old.contrast || next.blueOrangeDiff != old.blueOrangeDiff
            || next.ditherLight != old.ditherLight || next.ditherDark != old.ditherDark {
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
        if next.ditherGradientAnimates != old.ditherGradientAnimates {
            ditherGradientAnimates = next.ditherGradientAnimates
            changed = true
        }
        if next.ditherAccent != old.ditherAccent {
            ditherAccent = DitherAccent.named(next.ditherAccent)
            changed = true
        }
        if next.projectSprites != old.projectSprites { spritesOn = next.projectSprites; changed = true }
        if next.insetPanel != old.insetPanel { insetOn = next.insetPanel; changed = true }
        if next.ditherLight != old.ditherLight || next.ditherDark != old.ditherDark {
            dither = (next.ditherLight, next.ditherDark)
            ditherFlags = dither
            if next.ditherLight || next.ditherDark { SmoothCorners.install() }
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
        // Subviews' layers sit in this tree, so one walk turns every corner continuous, or back.
        if let layer = view.layer { SmoothCorners.sync(layer, smooth: SmoothCorners.active) }
        refreshViews(view)
    }

    private static func refreshViews(_ view: NSView) {
        view.viewDidChangeEffectiveAppearance()
        view.needsDisplay = true
        view.layer.map(redrawDecorations)
        for sub in view.subviews { refreshViews(sub) }
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
        let candyLight = input.ditherLight
        let candyDark = input.ditherDark
        let light = input.light == nil && stock && !candyLight ? nil
            : evaluate(input.light, contrast: input.contrast, contexts: (0, 2), candyTheme: candyLight)
        let dark = input.dark == nil && stock && !candyDark ? nil
            : evaluate(input.dark, contrast: input.contrast, contexts: (1, 3), candyTheme: candyDark)
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
                // index.css at 3814:1291-1301. Keep CandyWrapper's existing diff colors.
                case "--diff-added-icon" where !(dark ? candyDark : candyLight):
                    return ThemeCSSColor.transparent.token
                case "--diff-modified-icon" where !(dark ? candyDark : candyLight):
                    let muted = palette.mutedForeground
                    let alpha = dark ? 0.65 : 1.0
                    var srgb = muted.srgb, p3 = muted.displayP3
                    srgb.w *= alpha; p3.w *= alpha
                    return TokenColor(srgb: srgb, displayP3: p3)
                default: return members[i]
                }
            })
        }
        func redesign(_ palette: Palette, dark: Bool, sidebar: Bool) -> Palette {
            // Redesign light: the sidebar's menu icons, which T3 mixes toward the sidebar, take the muted icon color
            // so they keep 3:1, and success takes `capyLightSuccess`. The diff counts ("+59 −1" in the header pill,
            // the diff panel and the work log) are text, so they take success and the error text color: T3's
            // #00c590 and #fb2c36 read 2.3:1 and 3.7:1 on a white pill (2026-11-27 contrast table).
            var palette = palette
            if !dark, input.ditherLight {
                let members = palette.members, icon = palette.iconMuted, errorText = palette.errorForeground
                let success = ThemeCSSColor.parse(ThemeDefinition.capyLightSuccess)?.token
                palette = Palette(members: {
                    switch Palette.memberNames[$0] {
                    case "--sidebar-icon-color": icon
                    case "--success", "--success-foreground", "--diff-addition": success ?? members[$0]
                    case "--diff-deletion": errorText
                    default: members[$0]
                    }
                })
            }
            // Redesign dark: the same for the sidebar's menu icons, which T3's mix left at 2.6:1 (#505051 on #030303).
            if dark, input.ditherDark {
                let members = palette.members, icon = palette.iconMuted
                palette = Palette(members: { Palette.memberNames[$0] == "--sidebar-icon-color" ? icon : members[$0] })
            }
            // The main panel's lines become white overlays (dark) or black ones (light); its cards, bubbles and popovers
            // stay opaque, as do the sidebar and the panel's own background. Text keeps the theme's colors: a thread and
            // every page but the new thread sit on plain ground, and the new thread's cells fade out well above its
            // text, so they hold their floors (redesign-contrast-2026-11-27).
            if !sidebar, dark ? input.ditherDark : input.ditherLight {
                return WindowGlass.frosted(palette, dark: dark)
            }
            return palette
        }
        return ThemePalettes(light: redesign(diff(light?.0 ?? Tokens.light, dark: false), dark: false, sidebar: false),
                             dark: redesign(diff(dark?.0 ?? Tokens.dark, dark: true), dark: true, sidebar: false),
                             sidebarLight: redesign(diff(light?.1 ?? Tokens.sidebarLight, dark: false), dark: false, sidebar: true),
                             sidebarDark: redesign(diff(dark?.1 ?? Tokens.sidebarDark, dark: true), dark: true, sidebar: true))
    }

    private nonisolated static let parsedStandard = ThemeExpressions.standard.map { $0.map(parse) }
    private nonisolated static let parsedThemed = ThemeExpressions.themed.map { $0.map(parse) }
    private nonisolated static let parsedCandyStandard = CandyTheme3669.standard.map { $0.map(parse) }
    private nonisolated static let parsedCandyThemed = CandyTheme3669.themed.map { $0.map(parse) }
    private nonisolated static let candyIndices = Dictionary(uniqueKeysWithValues:
        CandyTheme3669.names.enumerated().map { ($0.element, $0.offset) })
    private nonisolated static let parsedBuiltIn = ThemeExpressions.builtIn.mapValues { $0.mapValues { $0.map(parse) } }

    private nonisolated static func parse(_ css: String) -> ThemeCSSExpression {
        ThemeCSSExpression.parse(css) ?? .literal(.transparent)
    }

    /// The main and sidebar palettes for one appearance (`contexts` index the expression columns).
    nonisolated static func evaluate(_ half: ThemeRuntimeHalf?, contrast: Int, contexts: (Int, Int), candyTheme: Bool = false) -> (Palette, Palette) {
        let percents = [
            "--appearance-contrast-base": Double(min(contrast, 100)),
            "--appearance-contrast-boost": Double(max(contrast - 100, 0)),
            "--appearance-contrast-border-boost": Double(max(contrast - 100, 0)) / 4,
        ]
        var colors: [String: ThemeCSSColor] = [:]
        for (role, value) in half?.colors ?? [:] { colors[role.cssVariable] = ThemeCSSColor.parse(value) }
        let table = half == nil ? parsedStandard : parsedThemed
        let candyTable = candyTheme ? (half == nil ? parsedCandyStandard : parsedCandyThemed) : []
        let builtIn = half?.builtInId.flatMap { parsedBuiltIn[$0] } ?? [:]
        func palette(_ column: Int) -> Palette {
            Palette(members: { i in
                if candyTheme, let oldIndex = candyIndices[Palette.memberNames[i]] {
                    if half == nil && contrast == 100 { return CandyTheme3669.colors[oldIndex][column] }
                    return candyTable[oldIndex][column].evaluate(colors: colors, percents: percents).token
                }
                return (builtIn[i]?[column] ?? table[i][column]).evaluate(colors: colors, percents: percents).token
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
