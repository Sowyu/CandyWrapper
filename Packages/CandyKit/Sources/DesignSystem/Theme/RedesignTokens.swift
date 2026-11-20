import AppKit

/// Redesign's tokens: every corner, shadow, surface fill, rim and state fill Redesign draws with, in one place.
/// docs/research/redesign-system.md argues for each value. RedesignTokenGuardTests fails when Redesign drawing code
/// writes a corner radius, a shadow or a surface opacity as a literal anywhere but this file.
public enum RedesignTokens {
    /// One corner per job, on continuous corners (`SmoothCorners`).
    public enum Radius {
        /// Buttons, inputs, rows, tabs, chips and the 30pt pills.
        public static let control: CGFloat = 8
        /// Cards, bubbles, code blocks, tables, banners and popovers.
        public static let card: CGFloat = 12
        /// The composer, the details card, the content panel and modals.
        public static let panel: CGFloat = 16
        /// The window's own corner, measured on macOS 27 for a titled window without a toolbar: a continuous 16, on
        /// this Mac at 1x and in the user's 2x capture (2026-10-22).
        /// ponytail: measured constant, read it from the window if a macOS release changes the frame's corner
        public static let window: CGFloat = 16
        /// The tight corner where two user bubbles of a burst meet.
        public static let joined: CGFloat = 6
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

    /// The glass recipes: a 12pt backdrop blur (`Tokens.LengthPx.glassBlur`), a fill and a 1pt rim.
    public enum Surface {
        /// Surfaces that rest on the picture: the composer, the pills, the header pill, cards.
        public static let resting: CGFloat = 0.62
        /// Layers over content, which must hide sharp text under them: menus, popovers, toasts, modals.
        public static let floating: CGFloat = 0.82
        /// A card on a surface, in the text color: code blocks, tables, user bubbles, tool output.
        public static let inset: CGFloat = 0.05
        /// The 1pt rim on every glass surface and card, in the text color.
        public static let rim: CGFloat = 0.08
        /// Increase Contrast's rim.
        public static let rimContrast: CGFloat = 0.24
        /// Under Reduce Transparency the backdrop is off, so fills go opaque, as system materials do.
        public static let opaque: CGFloat = 1

        /// The glass fill for `alpha` (`resting` or `floating`), opaque when the blur is off.
        @MainActor public static func fill(_ alpha: CGFloat, in view: NSView) -> CGColor {
            let dark = view.effectiveAppearance.isDark
            return Themed.color(dark ? \.surfaceRaised : \.card).cgColor(in: view).copy(alpha: blurs ? alpha : opaque)!
        }

        /// The fill of a card on a surface: a step in the text color.
        public nonisolated static func insetFill(dark: Bool) -> NSColor { dark ? Themed.white(inset) : Themed.black(inset) }

        /// The rim in the text color.
        public nonisolated static func rim(dark: Bool) -> NSColor {
            let a = increaseContrast ? rimContrast : rim
            return dark ? Themed.white(a) : Themed.black(a)
        }

        /// Reduce Transparency turns the system backdrop off, so `BackdropBlurView` draws nothing. "Ignore Reduce
        /// Transparency" brings the glass back, as the user asked (2026-10-28).
        @MainActor public static var blurs: Bool {
            !ThemeRuntime.reducesTransparency(system: reduceTransparencyOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)
        }
        /// Tests pin the setting here.
        @MainActor public static var reduceTransparencyOverride: Bool?

        nonisolated static var increaseContrast: Bool { NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }
    }

    /// A card on a surface (code blocks, tables, user bubbles, tool output): the inset fill, the rim, card corners,
    /// no shadow and no blur of its own.
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

    /// One curve; hover and press take `quick`, popovers and pills that appear take `appear`.
    public enum Motion {
        public static let quick: CFTimeInterval = 0.15
        public static let appear: CFTimeInterval = 0.2
        /// Capy's ease, `cubic-bezier(0.23, 1, 0.32, 1)`.
        @MainActor public static let curve = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
        /// How far a pill or popover rises as it appears.
        public static let rise: CGFloat = 4
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

    /// T3's radius for a box, under Dither: small controls 8, cards, popovers and bubbles 12, `rounded-3xl`
    /// surfaces 16 like the composer; hairline rounding and full pills unchanged.
    public static func radius(_ stock: CGFloat) -> CGFloat {
        switch stock {
        case ..<5: return stock
        case ..<9: return controlRadius
        case ..<20: return cardRadius
        case ..<30: return panelRadius
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
