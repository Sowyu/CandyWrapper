import AppKit

/// The default themes use 3814's token radii. CandyWrapper's own themes retain their 3669 geometry.
/// T3: apps/web/src/index.css:1115, with radius-sm/md/lg/xl/2xl derived from --radius.
public enum DesignGeometry {
    public static func usesClassic(_ view: NSView) -> Bool {
        ThemeRuntime.isDither(dark: view.effectiveAppearance.isDark)
    }

    /// Redesign maps T3's radius onto its own scale (`DitherChrome.radius`).
    public static func radius(_ previous: CGFloat, in view: NSView) -> CGFloat {
        if ThemeRuntime.isDither(dark: view.effectiveAppearance.isDark) { return DitherChrome.radius(previous) }
        return usesClassic(view) ? previous : max(0, previous - 2)
    }

    /// The corner of a small control's own fill (a hover, press or selection fill on a raw layer): Redesign's control
    /// radius, else `stock`. `radius(_:in:)` leaves anything under 5 alone, which kept such fills near square.
    public static func controlRadius(_ stock: CGFloat, in view: NSView) -> CGFloat {
        ThemeRuntime.isDither(dark: view.effectiveAppearance.isDark) ? RedesignTokens.Radius.control : stock
    }
}
