import Foundation

/// OKLCH (Ottosson 2020) to and from gamma-encoded sRGB, and WCAG contrast, for colors built from a hue such as the
/// project avatars' inks (`PixelSprites.inks`).
enum OKLCH {
    nonisolated static func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
    nonisolated static func enc(_ v: Double) -> Double { let v = min(max(v, 0), 1); return v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055 }
    nonisolated static func luminance(_ c: SIMD3<Double>) -> Double { 0.2126 * lin(c.x) + 0.7152 * lin(c.y) + 0.0722 * lin(c.z) }
    nonisolated static func contrast(_ a: Double, _ b: Double) -> Double { (max(a, b) + 0.05) / (min(a, b) + 0.05) }

    /// OKLCH of a gamma-encoded sRGB color.
    nonisolated static func oklch(srgb c: SIMD3<Double>) -> (l: Double, c: Double, h: Double) {
        let r = lin(c.x), g = lin(c.y), b = lin(c.z)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        let L = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        let A = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        let B = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        var h = atan2(B, A) * 180 / .pi
        if h < 0 { h += 360 }
        return (L, (A * A + B * B).squareRoot(), h)
    }

    /// Mid grey, the answer for a lightness or hue that is NaN or infinite.
    nonisolated static let nonFiniteFallback = SIMD3<Double>(repeating: 0.5)
    /// Above any sRGB color's OKLCH chroma (about 0.33), so the cap changes nothing a real color can reach and the
    /// fitting loop below runs at most `maxChroma / 0.002` steps.
    nonisolated static let maxChroma = 0.5

    /// Gamma-encoded sRGB at OKLCH, the chroma reduced until it fits sRGB. A NaN chroma counts as grey, an infinite
    /// or huge one as `maxChroma`, a lightness outside -1...2 as the nearer end, and a non-finite lightness or hue gives
    /// `nonFiniteFallback`.
    nonisolated static func srgb(oklch l: Double, _ c: Double, _ h: Double) -> SIMD3<Double> {
        guard l.isFinite, h.isFinite else { return nonFiniteFallback }
        // OKLCH lightness is 0...1. The wider clamp leaves every real color alone and keeps the cubes below finite.
        let l = min(max(l, -1), 2)
        func linear(_ c: Double) -> SIMD3<Double> {
            let a = c * cos(h * .pi / 180), b = c * sin(h * .pi / 180)
            let l_ = pow(l + 0.3963377774 * a + 0.2158037573 * b, 3)
            let m_ = pow(l - 0.1055613458 * a - 0.0638541728 * b, 3)
            let s_ = pow(l - 0.0894841775 * a - 1.2914855480 * b, 3)
            return SIMD3(4.0767416621 * l_ - 3.3077115913 * m_ + 0.2309699292 * s_,
                         -1.2684380046 * l_ + 2.6097574011 * m_ - 0.3413193965 * s_,
                         -0.0041960863 * l_ - 0.7034186147 * m_ + 1.7076147010 * s_)
        }
        var chroma = c.isNaN ? 0 : min(c, maxChroma)
        // Counted, so no input can spin it: 0.5 / 0.002 is 250 steps, the bound leaves room for rounding.
        for _ in 0..<Int(maxChroma / 0.002) + 2 where chroma > 0 {
            let v = linear(chroma)
            if v.min() >= -0.0005, v.max() <= 1.0005 { return SIMD3(enc(v.x), enc(v.y), enc(v.z)) }
            chroma -= 0.002
        }
        let v = linear(0)
        return SIMD3(enc(v.x), enc(v.y), enc(v.z))
    }
}
