import AppKit

/// T3's color scheme preference (`light`, `dark`, or following the system), applied through
/// AppKit's own appearance so dynamic colors re-resolve without any redraw code of ours.
public enum ColorSchemePreference: String, Sendable, CaseIterable {
    case system, light, dark

    @MainActor
    public func apply(to app: NSApplication = .shared) {
        switch self {
        case .system: app.appearance = nil
        case .light: app.appearance = NSAppearance(named: .aqua)
        case .dark: app.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

public extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}

extension TokenColor {
    /// Display P3 components: Chromium renders T3's oklch colors in the display's gamut, so
    /// P3 matches the official app on wide-gamut screens and converts exactly on sRGB ones.
    var nsColor: NSColor {
        NSColor(displayP3Red: displayP3.x, green: displayP3.y, blue: displayP3.z, alpha: displayP3.w)
    }
}

/// A color that follows the effective appearance of whatever draws it.
func dynamicColor(light: TokenColor, dark: TokenColor) -> NSColor {
    let l = light.nsColor, d = dark.nsColor
    return NSColor(name: nil) { $0.isDark ? d : l }
}

/// Semantic colors for the main surface and the sidebar subtree (`[data-app-sidebar]` in T3).
public struct ThemeColors: Sendable {
    let light: Palette
    let dark: Palette

    /// Builds a dynamic color for a palette member, for example `colors.color(\.background)`.
    public func color(_ key: KeyPath<Palette, TokenColor>) -> NSColor {
        dynamicColor(light: light[keyPath: key], dark: dark[keyPath: key])
    }

    public static let main = ThemeColors(light: Tokens.light, dark: Tokens.dark)
    public static let sidebar = ThemeColors(light: Tokens.sidebarLight, dark: Tokens.sidebarDark)
}

/// Interface scale. T3 sets `<html>` font-size from the `fontSizeInterface` setting
/// (default 16, range 12...20), and every rem-based token scales with it.
public enum Interface {
    nonisolated(unsafe) public static var remPixels: CGFloat = 16 // ponytail: global, make it observable when the settings screen exists

    public static func rem(_ value: CGFloat) -> CGFloat { value * remPixels }
}
