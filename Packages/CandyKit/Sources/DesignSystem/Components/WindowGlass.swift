import AppKit

/// Color math Redesign's palette uses: WCAG luminance, and turning lines and light fills into overlays (`frosted`).
/// Also the floating fill Redesign gives dialogs and toasts.
public enum WindowGlass {
    nonisolated static func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    nonisolated static func gamma(_ c: Double) -> Double { c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055 }
    /// WCAG relative luminance.
    nonisolated static func luminance(_ c: TokenColor) -> Double {
        0.2126 * linear(c.srgb.x) + 0.7152 * linear(c.srgb.y) + 0.0722 * linear(c.srgb.z)
    }

    /// Muted text roles that T3 also paints faded (`/70`, `/60`, the composer's placeholder at 75%); Redesign light
    /// paints them at full strength.
    nonisolated(unsafe) static let frostFullStrength: Set<KeyPath<Palette, TokenColor>> = [
        \.mutedForeground, \.contrastMutedForeground, \.sidebarMutedForeground, \.contrastSidebarMutedForeground,
        \.secondaryLabel, \.contrastSecondaryLabel, \.placeholder, \.contrastPlaceholder,
    ]

    /// The muted text roles Redesign dark paints at full strength in the main panel.
    nonisolated(unsafe) static let ditherFullStrength: Set<KeyPath<Palette, TokenColor>> = [
        \.mutedForeground, \.contrastMutedForeground, \.secondaryLabel, \.contrastSecondaryLabel,
    ]

    /// Light fills and lines that T3 paints opaque, a step off the background. In light, each becomes the black
    /// overlay that paints the same color over the stock background, so it tints whatever sits on the art.
    /// Dark already paints these as white overlays. The user bubble (`--message-surface`) and inline code (`--muted`)
    /// stay opaque: as overlays the picture's dots showed through their text (round-0 review, W7 and T1).
    nonisolated static let tintMembers: Set<String> = [
        "--accent", "--secondary", "--sidebar-control-surface", "--toolbar-control-hover",
        "--sidebar-row-hover", "--border", "--contrast-border", "--sidebar-border", "--contrast-sidebar-border",
        "--input", "--contrast-input", "--toolbar-border", "--contrast-toolbar-border",
    ]

    /// The lines among them. Redesign's dark palette paints them opaque, a step off the panel (the sidebar and toolbar
    /// borders a step darker), so over the art they read near black; `frosted` turns them into white overlays like
    /// the composer's border, at any contrast.
    nonisolated static let lineMembers: Set<String> = [
        "--border", "--contrast-border", "--input", "--contrast-input", "--sidebar-border", "--contrast-sidebar-border",
        "--toolbar-border", "--contrast-toolbar-border",
    ]

    /// Redesign's main panel palette with its lines and light fills turned into overlays. Its surfaces stay opaque
    /// (the user, 2026-11-21: "in redesign no more blurs").
    nonisolated static func frosted(_ palette: Palette, dark: Bool) -> Palette {
        let members = palette.members
        let base = palette.background
        return Palette(members: { i in
            let c = members[i], name = Palette.memberNames[i]
            if lineMembers.contains(name) {
                // A contrast below 100 mixes the line toward transparent: overlay its color, then keep that alpha.
                var line = overlay(c, over: base)
                // A line darker than the panel would paint black; it takes the border's white instead.
                if dark, line.srgb.x == 0 { line = overlay(palette.border, over: base) }
                return line.withAlpha(c.srgb.w)
            }
            guard c.srgb.w >= 1 else { return c }
            if !dark, tintMembers.contains(name) { return overlay(c, over: base) }
            return c
        })
    }

    /// The black or white overlay that paints `color` over `base`.
    nonisolated static func overlay(_ color: TokenColor, over base: TokenColor) -> TokenColor {
        let c = (color.srgb.x + color.srgb.y + color.srgb.z) / 3, b = (base.srgb.x + base.srgb.y + base.srgb.z) / 3
        if c <= b {
            let a = b > 0 ? min(1, 1 - c / b) : 1
            return TokenColor(srgb: SIMD4(0, 0, 0, a), displayP3: SIMD4(0, 0, 0, a))
        }
        let a = b < 1 ? min(1, (c - b) / (1 - b)) : 1
        return TokenColor(srgb: SIMD4(1, 1, 1, a), displayP3: SIMD4(1, 1, 1, a))
    }

    /// A floating surface's fill (dialogs, the command palette, toasts): T3's `stock` fill, or Redesign's popover.
    public static func floating(stock: NSColor) -> NSColor {
        let solid = Themed.color(\.popover)
        return NSColor(name: nil) { resolve(ThemeRuntime.isDither(dark: $0.isDark) ? solid : stock, in: $0) }
    }

    /// A dynamic color's concrete value in `appearance`, for color providers that pick between dynamic colors.
    nonisolated static func resolve(_ color: NSColor, in appearance: NSAppearance) -> NSColor {
        var resolved = color
        appearance.performAsCurrentDrawingAppearance { resolved = NSColor(cgColor: color.cgColor) ?? color }
        return resolved
    }
}
