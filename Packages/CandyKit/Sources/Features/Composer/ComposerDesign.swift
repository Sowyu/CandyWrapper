import AppKit
import DesignSystem

/// CandyWrapper's own themes keep their existing composer and chip geometry.
enum ComposerDesign {
    static func uses3814(dark: Bool) -> Bool {
        !ThemeRuntime.isDither(dark: dark) && !ThemeRuntime.isGlass(dark: dark)
    }
    static var current: Bool { uses3814(dark: NSAppearance.currentDrawing().isDark) }
}
