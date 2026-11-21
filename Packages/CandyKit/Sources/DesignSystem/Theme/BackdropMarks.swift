import AppKit

/// Marks painted straight on Redesign's picture, where no single background sits behind them. T3's
/// translucent marks would vanish over a bright dot, and the full-strength muted text rule (`ThemedColorCache`) would
/// make every state as bright as the readable text. So each state becomes one opaque color that keeps the contrast
/// ratio to the resting state that T3's marks have on T3's own panel, with the resting state as far from the worst
/// dot behind it as T3's resting mark is from T3's panel, or as far as the first `keep` states still allow. States after
/// those keep their ratio only up to white (dark) or black (light).
public enum BackdropMarks {
    /// One layer of a T3 mark: `key` at `alpha`, painted over the layers before it.
    public struct Layer {
        public let key: KeyPath<Palette, TokenColor>
        public let alpha: Double
        public init(_ key: KeyPath<Palette, TokenColor>, _ alpha: Double) { self.key = key; self.alpha = alpha }
    }

    /// The background gray (sRGB) a mark must still show over in the main panel: the brightest art dot (dark) or the
    /// darkest (light), without the chat column's veil, since marks sit beside the column. Nil on a solid panel.
    nonisolated static func worstBackground(dark: Bool) -> Double? {
        let background = ThemeRuntime.palettes.palette(dark: dark, sidebar: false).background
        if ThemeRuntime.isDither(dark: dark) {
            // Picture lays no dim, so its marks keep the default dim's strength whatever the slider says.
            let picture = !ThemeRuntime.ditherBlur
            return DitherArt.worstBackground(background, dark: dark, dim: picture ? DitherArt.defaultDim : Double(ThemeRuntime.ditherDim), veiled: false)
        }
        return nil
    }

    /// The WCAG luminance of each state of T3's marks on T3's own panel, state 0 resting, and of that panel.
    nonisolated static func reference(_ states: [[Layer]], dark: Bool) -> (background: Double, states: [Double]) {
        let palette = dark ? Tokens.dark : Tokens.light
        let ground = palette.background.srgb
        let states = states.map { layers in
            var c = SIMD3(ground.x, ground.y, ground.z)
            for layer in layers {
                let top = palette[keyPath: layer.key].srgb, a = top.w * layer.alpha
                c = c * (1 - a) + SIMD3(top.x, top.y, top.z) * a
            }
            return luminance(c)
        }
        return (luminance(SIMD3(ground.x, ground.y, ground.z)), states)
    }

    /// Target luminances over a worst background of luminance `lw`, keeping T3's ratios (see the type's comment).
    nonisolated static func luminances(_ states: [[Layer]], keep: Int, dark: Bool, over lw: Double) -> [Double] {
        let ref = reference(states, dark: dark)
        let resting = contrast(ref.states[0], ref.background)
        let ratios = ref.states.map { contrast($0, ref.states[0]) }
        let top = ratios.prefix(keep).max() ?? 1
        if dark {
            let rest = min(resting * (lw + 0.05) - 0.05, 1.05 / top - 0.05)
            return ratios.map { min($0 * (rest + 0.05) - 0.05, 1) }
        }
        let rest = max((lw + 0.05) / resting - 0.05, 0.05 * top - 0.05)
        return ratios.map { max((rest + 0.05) / $0 - 0.05, 0) }
    }

    /// The opaque color for each state, in the hue of its top layer in the current palette, or nil where the panel
    /// is solid and T3's translucent marks draw as they are.
    public static func colors(_ states: [[Layer]], keep: Int? = nil, dark: Bool) -> [NSColor]? {
        guard let worst = worstBackground(dark: dark) else { return nil }
        let palette = ThemeRuntime.palettes.palette(dark: dark, sidebar: false)
        let targets = luminances(states, keep: keep ?? states.count, dark: dark, over: WindowGlass.linear(worst))
        return zip(states, targets).map { layers, l in
            withLuminance(palette[keyPath: layers.last!.key], l).nsColor
        }
    }

    /// `color` moved in linear light to luminance `l`: toward white to brighten, scaled toward black to darken.
    nonisolated static func withLuminance(_ color: TokenColor, _ l: Double) -> TokenColor {
        let lin = SIMD3(WindowGlass.linear(color.srgb.x), WindowGlass.linear(color.srgb.y), WindowGlass.linear(color.srgb.z))
        let now = WindowGlass.luminance(color), l = min(max(l, 0), 1)
        let out = l >= now ? lin + (SIMD3(repeating: 1) - lin) * ((l - now) / max(1 - now, 1e-6)) : lin * (l / max(now, 1e-6))
        return ThemeCSSColor(srgb: WindowGlass.gamma(out.x), WindowGlass.gamma(out.y), WindowGlass.gamma(out.z)).token
    }

    nonisolated static func luminance(_ c: SIMD3<Double>) -> Double {
        0.2126 * WindowGlass.linear(c.x) + 0.7152 * WindowGlass.linear(c.y) + 0.0722 * WindowGlass.linear(c.z)
    }

    nonisolated static func contrast(_ a: Double, _ b: Double) -> Double { (max(a, b) + 0.05) / (min(a, b) + 0.05) }
}
