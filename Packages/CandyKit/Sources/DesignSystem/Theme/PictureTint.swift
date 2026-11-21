import AppKit

/// Redesign's "Tint from picture" (the user, 2026-11-21: "very slightly tint the ui to the pictures colours"): the
/// picture's mean color, as an OKLab a and b, mixed a little into the neutral surfaces of the palette. Each surface
/// keeps its lightness, so text contrast barely moves. The tint is computed once per picture on a worker and cached;
/// drawing reads the tinted palette like any other theme color.
public enum PictureTint {
    /// The share of the picture's a and b each neutral surface takes. 5% reads only side by side.
    public nonisolated static let mix: Double = 0.05
    /// A whole picture's mean is far greyer than any part of it (0.03 for the default Golden Gate picture, 0.05 for
    /// Radial Sky Blue, under 0.01 for Sonoma), so its chroma is scaled by this before the cap.
    public nonisolated static let gain: Double = 3
    /// The picture's chroma is capped here before mixing, so a saturated picture tints no more than a muted one.
    public nonisolated static let maxChroma: Double = 0.1
    /// A surface whose own chroma is over this is a colored role and keeps its color.
    nonisolated static let neutralChroma: Double = 0.02
    /// The roles that are surfaces: ground, sidebar, chrome, composer and pills, cards, menus, inputs, bubbles, code,
    /// and the opaque lines between them. Text, icons and colored roles keep their values.
    nonisolated static let surfaces: Set<String> = [
        "--background", "--app-chrome-background", "--card", "--popover", "--surface-raised", "--muted", "--secondary",
        "--accent", "--input", "--border", "--sidebar", "--sidebar-border", "--sidebar-control-surface",
        "--toolbar-background", "--toolbar-border", "--toolbar-control", "--toolbar-control-hover", "--message-surface",
        "--code-background", "--terminal-background",
    ]

    /// The mean color of `picture` in linear light, as an OKLab a and b scaled by `gain` and capped at `maxChroma`.
    public nonisolated static func tint(of picture: CGImage) -> SIMD2<Double> {
        let n = 16
        guard let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let data = ctx.data?.bindMemory(to: UInt8.self, capacity: n * n * 4) else { return .zero }
        ctx.interpolationQuality = .medium
        ctx.draw(picture, in: CGRect(x: 0, y: 0, width: n, height: n))
        var sum = SIMD3<Double>.zero
        for i in 0..<(n * n) {
            sum += SIMD3((0..<3).map { ThemeCSSColor.linear(Double(data[i * 4 + $0]) / 255) })
        }
        let mean = sum / Double(n * n)
        let lab = ThemeCSSColor(srgb: ThemeCSSColor.gamma(mean.x), ThemeCSSColor.gamma(mean.y), ThemeCSSColor.gamma(mean.z)).lab
        return capped(SIMD2(lab.y, lab.z) * gain)
    }

    nonisolated static func capped(_ ab: SIMD2<Double>) -> SIMD2<Double> {
        let c = (ab * ab).sum().squareRoot()
        return c > maxChroma ? ab * (maxChroma / c) : ab
    }

    /// `palette` with `tint` mixed into its neutral, opaque surfaces at `mix`, in OKLab, keeping each one's lightness.
    public nonisolated static func apply(_ tint: SIMD2<Double>, to palette: Palette) -> Palette {
        let tint = capped(tint)
        let members = palette.members
        return Palette(members: { i in
            let c = members[i]
            guard surfaces.contains(Palette.memberNames[i]), c.srgb.w >= 1 else { return c }
            var lab = ThemeCSSColor(srgb: c.srgb.x, c.srgb.y, c.srgb.z).lab
            guard (lab.y * lab.y + lab.z * lab.z).squareRoot() <= neutralChroma else { return c }
            lab.y += (tint.x - lab.y) * mix
            lab.z += (tint.y - lab.z) * mix
            // Back into sRGB's gamut: white with a tint would otherwise ask for a channel over 1.
            let s = ThemeCSSColor(lab: lab).srgb.clamped(lowerBound: .zero, upperBound: SIMD3(repeating: 1))
            return ThemeCSSColor(srgb: s.x, s.y, s.z).token
        })
    }

    /// Tints already computed, by the picture's path.
    @MainActor private static var cache: [URL: SIMD2<Double>] = [:]
    @MainActor private static var computing: Set<URL> = []
    /// The picture the art shows now, so a late result for an older one is dropped.
    @MainActor private static var current: URL?

    /// Hands the theme runtime the tint of the first of `urls` that decodes (the art's picture, then its fallbacks),
    /// from the cache, or computes it once on a worker. Costs a dictionary lookup when the picture is unchanged.
    @MainActor public static func sync(_ urls: [URL]) {
        guard let key = urls.first else { return }
        current = key
        if let tint = cache[key] { ThemeRuntime.setPictureTint(tint); return }
        guard computing.insert(key).inserted else { return }
        DispatchQueue.global(qos: .utility).async {
            let picture = urls.lazy.compactMap { DitherArt.picture($0, maxPixels: 64) }.first ?? DitherArt.builtInPicture()
            let tint = picture.map(Self.tint(of:)) ?? .zero
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    computing.remove(key)
                    cache[key] = tint
                    if current == key { ThemeRuntime.setPictureTint(tint) }
                }
            }
        }
    }
}
