import AppKit
import DesignSystem

/// CandyWrapper's own themes keep their existing composer and chip geometry.
enum ComposerDesign {
    static func uses3814(dark: Bool) -> Bool {
        !ThemeRuntime.isDither(dark: dark) && !ThemeRuntime.isGlass(dark: dark)
    }
    static var current: Bool { uses3814(dark: NSAppearance.currentDrawing().isDark) }
    /// Nightly 3824's grouped footer controls (#25869): effort as a word or bars, permissions in the effort menu and the
    /// controls beside send. Redesign takes them on its own pill; Glass keeps its controls.
    static func groupedControls(dark: Bool) -> Bool { uses3814(dark: dark) || ThemeRuntime.isDither(dark: dark) }
}
