import AppKit

/// Redesign's tokens: every corner, shadow, surface fill, rim and state fill Redesign draws with, in one place.
/// docs/research/redesign-system.md argues for each value. RedesignTokenGuardTests fails when Redesign drawing code
/// writes a corner radius, a shadow or a surface opacity as a literal anywhere but this file.
public enum RedesignTokens {
    /// One corner for every surface and one for what sits inside them, on continuous corners (`SmoothCorners`). The
    /// user, 2026-11-21: "make all corner radiuses the same", with a tight corner like corner-radius-target.png
    /// (a circular 7.5pt, measured at 2x).
    public enum Radius {
        /// Cards, bubbles, code blocks, tables, banners, menus, popovers, the pills, the composer, the content panel,
        /// modals and inputs.
        public static let card: CGFloat = 8
        /// The same corner, named for the large surfaces: the composer, the details card, the content panel, modals.
        public static let panel: CGFloat = card
        /// What sits inside a surface: buttons, menu rows, sidebar rows, tabs, chips and segmented selections.
        /// Concentric with `card` at a 2pt inset, the segmented track's.
        public static let control: CGFloat = nested(in: card, inset: 2)
        /// The window's own corner, measured on macOS 27 for a titled window without a toolbar: a continuous 16, on
        /// this Mac at 1x and in the user's 2x capture (2026-10-22).
        /// ponytail: measured constant, read it from the window if a macOS release changes the frame's corner
        public static let window: CGFloat = 16
        /// The tight corner where two user bubbles of a burst meet.
        public static let joined: CGFloat = 3
        /// The concentric corner for a shape `inset` inside one with corner `outer`, so both curves run parallel.
        public static func nested(in outer: CGFloat, inset: CGFloat) -> CGFloat { max(2, outer - inset) }
        /// A dot, a ring or a line with round ends: half its height. A shape, not a step on the scale.
        public static func capsule(_ height: CGFloat) -> CGFloat { height / 2 }
    }

    /// The spacing scale. Inside a control 2, 6, 10 and 14 are allowed too.
    public enum Space {
        public static let xs: CGFloat = 4
        public static let s: CGFloat = 8
        public static let m: CGFloat = 12
        public static let l: CGFloat = 16
        public static let xl: CGFloat = 24
        public static let xxl: CGFloat = 32
        /// A pill's and the header pill's control height.
        public static let pill: CGFloat = 30
    }

    /// Two shadows: one for surfaces that rest on the picture, one for layers that float over content.
    public struct Shadow: Sendable {
        public let y: CGFloat
        /// `CALayer.shadowRadius`; CSS blur is twice this.
        public let radius: CGFloat
        public let dark: Float
        public let light: Float

        /// The composer, the pills, the header pill and every card on the picture.
        public static let resting = Shadow(y: 2, radius: 4, dark: 0.28, light: 0.08)
        /// Menus, popovers, the docked picker, tooltips, toasts and modals.
        public static let floating = Shadow(y: 8, radius: 12, dark: 0.45, light: 0.12)

        public func opacity(dark isDark: Bool) -> Float { isDark ? dark : light }

        /// Puts the shadow on a layer that draws only the shadow, along `path`.
        @MainActor public func apply(to layer: CALayer, path: CGPath, dark isDark: Bool) {
            layer.shadowColor = NSColor.black.cgColor
            layer.shadowOpacity = opacity(dark: isDark)
            layer.shadowRadius = radius
            layer.shadowOffset = CGSize(width: 0, height: layer.isGeometryFlipped ? y : -y)
            layer.shadowPath = path
        }

        /// The same shadow for `BoxStyle`, whose blur is CSS's.
        @MainActor public var box: BoxShadow {
            let d = CGFloat(dark), l = CGFloat(light)
            return BoxShadow(y: y, blur: radius * 2, color: NSColor(name: nil) { $0.isDark ? .black.withAlphaComponent(d) : .black.withAlphaComponent(l) })
        }
    }

    /// Solid surfaces: an opaque fill, a 1pt hairline rim and the token shadow. Redesign draws no backdrop blur (the
    /// user, 2026-11-21: "in redesign no more blurs its no premium").
    public enum Surface {
        /// A card on a surface, in the text color over the panel's ground: code blocks, tables, tool output.
        public static let inset: CGFloat = 0.05
        /// The 1pt rim on every surface and card, in the text color.
        public static let rim: CGFloat = 0.08
        /// Increase Contrast's rim.
        public static let rimContrast: CGFloat = 0.24
        /// The black at the foot of the gradient that keeps a caption readable over a picture (the agent gallery).
        public static let shade: CGFloat = 0.62

        /// The fill of a surface that rests on the ground: the composer, the pills, the header pill, Settings.
        @MainActor public static func fill(in view: NSView) -> CGColor {
            let dark = view.effectiveAppearance.isDark
            return Themed.color(dark ? \.surfaceRaised : \.card).cgColor(in: view)
        }

        /// The fill of a card on a surface: a step in the text color over the panel's ground, opaque so the picture
        /// never shows through it.
        public nonisolated static func insetFill(dark: Bool) -> NSColor {
            let g = ThemeRuntime.palettes.palette(dark: dark, sidebar: false).background.srgb
            let a = Double(inset), top: Double = dark ? 1 : 0
            func mix(_ c: Double) -> CGFloat { CGFloat(c * (1 - a) + top * a) }
            return NSColor(srgbRed: mix(g.x), green: mix(g.y), blue: mix(g.z), alpha: 1)
        }

        /// The rim in the text color.
        public nonisolated static func rim(dark: Bool) -> NSColor {
            let a = increaseContrast ? rimContrast : rim
            return dark ? Themed.white(a) : Themed.black(a)
        }

        nonisolated static var increaseContrast: Bool { NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }
    }

    /// A card on a surface (code blocks, tables, tool output): the opaque inset fill, the rim, card corners, no
    /// shadow.
    public enum Card {
        public static let radius = Radius.card
        public static let fill = NSColor(name: nil) { Surface.insetFill(dark: $0.isDark) }
        public static let border = NSColor(name: nil) { Surface.rim(dark: $0.isDark) }
    }

    /// Hover, pressed and selected fills, in the text color, the same on every Redesign control.
    public enum State {
        public static let hover: CGFloat = 0.06
        public static let pressed: CGFloat = 0.1
        public static let selected: CGFloat = 0.1
        public nonisolated static func fill(_ alpha: CGFloat, dark: Bool) -> NSColor {
            // Light needs less: black reads stronger than white at the same alpha.
            dark ? Themed.white(alpha) : Themed.black(alpha * 0.7)
        }
        /// A control's fill: pressed while held or while its menu is open, hover under the pointer, else none.
        @MainActor public static func fill(_ state: ControlView.State, dark: Bool) -> NSColor? {
            state.activeOrPressed ? fill(pressed, dark: dark) : state.hovered ? fill(hover, dark: dark) : nil
        }
    }

    /// Redesign's one motion system (docs/research/redesign-motion-2026-11-21.md). Three durations, one curve in and one
    /// out. Everything that opens (menus, popovers, pills, toasts, modals, the right panel) moves with these; nothing
    /// runs longer than `large`, and no surface waits for its animation before it takes clicks or keys.
    public enum Motion {
        /// Exits, the hover fade out and the press.
        public static let fast: CFTimeInterval = 0.12
        /// Menus, popovers, pills, toasts restacking, the segmented selection.
        public static let standard: CFTimeInterval = 0.15
        /// Modals and their backdrop, the right panel, toasts arriving.
        public static let large: CFTimeInterval = 0.2
        /// One cycle of a decorative loop: the skeleton's pulse, the waiting chip's dots. Loops run only while shown.
        public static let loop: CFTimeInterval = 1.2
        /// Earlier names, kept for the gallery and chart code that uses them.
        public static let quick = standard
        public static let appear = large
        /// Capy's ease-out, `cubic-bezier(0.23, 1, 0.32, 1)`, for everything that arrives or moves.
        @MainActor public static let curve = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
        /// The ease-in for everything that leaves.
        @MainActor public static let exitCurve = CAMediaTimingFunction(controlPoints: 0.4, 0, 1, 1)
        /// How far a pill or toast travels as it appears or leaves.
        public static let rise: CGFloat = 4
        /// The scale a popover, menu or modal opens from and closes to, about its anchor edge.
        public static let scale: CGFloat = 0.98
        /// A pressed button's scale.
        public static let pressScale: CGFloat = 0.98
        /// How far the right panel travels as it opens or closes.
        public static let panelShift: CGFloat = 12

        @MainActor public static func timing(entering: Bool) -> CAMediaTimingFunction { entering ? curve : exitCurve }
        /// `standard` in, `fast` out.
        public static func popover(entering: Bool) -> CFTimeInterval { entering ? standard : fast }
    }
}

/// The Dither theme's metrics, after Capy's desktop app, on `RedesignTokens`.
public enum DitherChrome {
    public static let cardRadius = RedesignTokens.Radius.card
    public static let controlRadius = RedesignTokens.Radius.control
    public static let panelRadius = RedesignTokens.Radius.panel
    public static let windowRadius = RedesignTokens.Radius.window
    /// The tab strip band above the content panel: 52, the titlebar row everywhere else (traffic lights, sidebar header), so the tabs share their centre line.
    public static let band: CGFloat = 52

    /// The band's color: the art's top fade starts from it at the window's top edge (DitherArtView).
    @MainActor public static func bandColor(in view: NSView) -> CGColor { Themed.color(\.sidebar, sidebar: true).cgColor(in: view) }

    /// How much of the band's color covers the panel at `t`, 0 at the panel's top to 1 at the blend's bottom: all of it at
    /// the top edge, so band and panel meet in one color, then falling off at once, so no solid strip shows under the
    /// band (the user: "make the fade start from the very top and just remove the black part").
    public nonisolated static func bandBlend(_ t: Double) -> Double {
        let x = min(1, max(0, t))
        return (1 - x) * (1 - x)
    }

    /// T3's radius for a box, under Dither: small controls take the control corner, everything from cards up the one
    /// surface corner; hairline rounding and full pills unchanged.
    public static func radius(_ stock: CGFloat) -> CGFloat {
        switch stock {
        case ..<5: return stock
        case ..<9: return controlRadius
        case ..<30: return cardRadius
        default: return stock
        }
    }

    /// The corner for a shape `inset` inside one with corner `outer` (the user, 2026-10-22: "the corner radiuses for
    /// everything isnt consistent").
    public static func nested(in outer: CGFloat, inset: CGFloat) -> CGFloat { RedesignTokens.Radius.nested(in: outer, inset: inset) }

    /// The 1pt rim every floating surface draws on its continuous corner (the user, 2026-10-23: "an outline like the
    /// prompting field and the stash").
    public nonisolated static func rim(dark: Bool) -> NSColor { RedesignTokens.Surface.rim(dark: dark) }
}
