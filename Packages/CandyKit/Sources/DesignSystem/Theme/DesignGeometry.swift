import AppKit

/// The default themes use 3814's token radii. CandyWrapper's own themes retain their 3669 geometry.
/// T3: apps/web/src/index.css:1115, with radius-sm/md/lg/xl/2xl derived from --radius.
public enum DesignGeometry {
    public static func usesClassic(_ view: NSView) -> Bool {
        ThemeRuntime.framesPanes(dark: view.effectiveAppearance.isDark)
    }

    public static func radius(_ previous: CGFloat, in view: NSView) -> CGFloat {
        usesClassic(view) ? previous : max(0, previous - 2)
    }
}
