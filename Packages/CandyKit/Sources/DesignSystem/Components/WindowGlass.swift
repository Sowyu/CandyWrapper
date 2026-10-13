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
    // ponytail: fixed colors tuned at the default opacity; derive them from `alpha` if users run Glass far lower
    nonisolated static let mutedLight = ThemeCSSColor.parse("#6b6b74")!.token
    nonisolated static let mutedDark = ThemeCSSColor.parse("#959595")!.token
    nonisolated static let mutedMembers: Set<String> = ["--muted-foreground", "--contrast-muted-foreground", "--sidebar-muted-foreground",
                                                       "--contrast-sidebar-muted-foreground", "--icon-muted", "--contrast-icon-muted"]

    /// `palette` with its muted text moved to Glass's readable muted color where the stock one is fainter.
    nonisolated static func readableMuted(_ palette: Palette, dark: Bool) -> Palette {
        let target = dark ? mutedDark : mutedLight
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
}

/// The frost itself: a behind-window visual effect view that keeps the system's material and blur but paints
/// nothing of its own on top. The window server composites it; it has no backing store in this process.
final class WindowGlassBackdropView: NSVisualEffectView {
    override init(frame frameRect: NSRect) {
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
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
}
