import Foundation
import Testing
@testable import DesignSystem

/// `OKLCH.srgb(oklch:)` ends for any input and gives the same bits as before for every color a caller can reach.
struct OKLCHGuardTests {
    /// The function before the guard, kept to compare against.
    static func oldSRGB(_ l: Double, _ c: Double, _ h: Double) -> SIMD3<Double> {
        func linear(_ c: Double) -> SIMD3<Double> {
            let a = c * cos(h * .pi / 180), b = c * sin(h * .pi / 180)
            let l_ = pow(l + 0.3963377774 * a + 0.2158037573 * b, 3)
            let m_ = pow(l - 0.1055613458 * a - 0.0638541728 * b, 3)
            let s_ = pow(l - 0.0894841775 * a - 1.2914855480 * b, 3)
            return SIMD3(4.0767416621 * l_ - 3.3077115913 * m_ + 0.2309699292 * s_,
                         -1.2684380046 * l_ + 2.6097574011 * m_ - 0.3413193965 * s_,
                         -0.0041960863 * l_ - 0.7034186147 * m_ + 1.7076147010 * s_)
        }
        var chroma = c
        while chroma > 0 {
            let v = linear(chroma)
            if v.min() >= -0.0005, v.max() <= 1.0005 { return SIMD3(OKLCH.enc(v.x), OKLCH.enc(v.y), OKLCH.enc(v.z)) }
            chroma -= 0.002
        }
        let v = linear(0)
        return SIMD3(OKLCH.enc(v.x), OKLCH.enc(v.y), OKLCH.enc(v.z))
    }

    @Test func reachableInputsAreBitIdentical() {
        var n = 0
        // Every OKLCH an sRGB color maps to, on a 17-step cube, plus a plain grid up to past the sRGB chroma limit.
        for r in 0...16 { for g in 0...16 { for b in 0...16 {
            let o = OKLCH.oklch(srgb: SIMD3(Double(r), Double(g), Double(b)) / 16)
            for k in [1.0, 0.5, 1.3] {
                #expect(OKLCH.srgb(oklch: o.l, o.c * k, o.h) == Self.oldSRGB(o.l, o.c * k, o.h)); n += 1
            }
        } } }
        for li in 0...20 { for ci in 0...45 { for hi in 0..<36 {
            let l = Double(li) / 20, c = Double(ci) / 100, h = Double(hi) * 10
            #expect(OKLCH.srgb(oklch: l, c, h) == Self.oldSRGB(l, c, h)); n += 1
        } } }
        #expect(n > 30_000)
    }

    @Test func hostileInputsEndQuicklyWithADefinedColor() {
        let start = Date()
        for l in [0.5, -1, 2, 1e300] { for c in [Double.nan, .infinity, -.infinity, -1, 1e300, 1e9] {
            let v = OKLCH.srgb(oklch: l, c, 40)
            #expect(v.x.isFinite && v.y.isFinite && v.z.isFinite)
        } }
        // Infinite or huge chroma is the same as the cap, and NaN chroma is grey.
        #expect(OKLCH.srgb(oklch: 0.6, .infinity, 40) == OKLCH.srgb(oklch: 0.6, OKLCH.maxChroma, 40))
        #expect(OKLCH.srgb(oklch: 0.6, .nan, 40) == OKLCH.srgb(oklch: 0.6, 0, 40))
        for (l, h) in [(Double.nan, 40.0), (.infinity, 40), (0.5, .nan), (0.5, -.infinity)] {
            #expect(OKLCH.srgb(oklch: l, 0.1, h) == OKLCH.nonFiniteFallback)
        }
        #expect(Date().timeIntervalSince(start) < 1)
    }
}
