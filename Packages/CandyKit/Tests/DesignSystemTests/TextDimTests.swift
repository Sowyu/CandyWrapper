import AppKit
import Testing
@testable import DesignSystem

/// "Dim behind text": the default reproduces the earlier fixed look in every background, 0 holds nothing back, and the
/// strength only grows with the position.
struct TextDimTests {
    let w = 480, h = 64, ground = SIMD3<Double>(repeating: 8.0 / 255)
    let column: [Double] = [360, 0, 720, 192]
    let text: [SIMD3<Double>] = [SIMD3(repeating: 0xf5 / 255.0), SIMD3(0xaa, 0xaa, 0xab) / 255.0]

    func render(_ value: UInt8, _ shape: PictureInk.Shape, dim: Int?, dark: Bool = true) throws -> [UInt8] {
        let tone = PictureInk.Tone(width: w, height: h, values: (0..<(w * h)).map { UInt8(truncatingIfNeeded: value &+ UInt8($0 % 40)) },
                                   hue: 0, median: 0.5)
        let inks = PictureInk.inks(hue: 200)
        let art = try #require(dim.map { PictureInk.render(tone, inks: inks, ground: ground, dark: dark, shape: shape, text: text, dim: $0) }
            ?? PictureInk.render(tone, inks: inks, ground: ground, dark: dark, shape: shape, text: text))
        return [UInt8](art.dataProvider!.data! as Data)
    }

    @Test func defaultIsTheEarlierLook() throws {
        // Flower: the mask's shares are the constants exactly.
        for cap: Float in [0.1, 0.27, 0.5] { #expect(DitherArtView.flowerShare(cap, dim: TextDim.standard) == cap) }
        #expect(DitherArtView.flowerShare(LotusArt.columnKeep, dim: TextDim.standard) == LotusArt.columnKeep)
        // Picture: the floors' bound is the floors' own, in both appearances.
        for dark in [true, false] {
            let b = PictureInk.textBound(text, dark: dark)
            #expect(TextDim.pictureBound(b, groundY: PictureInk.luminance(ground), dark: dark, at: TextDim.standard) == b)
        }
        #expect(PictureInk.floors(dark: true) == (15, 7.5))
        #expect(try render(200, .thread(column: column), dim: TextDim.standard) == render(200, .thread(column: column), dim: nil))
        // Blur: the stored 35% sits at the default, and the track's ends at none and 90.
        #expect(TextDim.blurDim(at: TextDim.standard) == 35 && TextDim.position(blurDim: 35) == TextDim.standard)
        #expect(TextDim.blurDim(at: 0) == 0 && TextDim.blurDim(at: 100) == 90)
    }

    @Test func zeroHoldsNothingBack() throws {
        #expect(try render(200, .thread(column: column), dim: 0) == render(200, .plain, dim: 0))
        #expect(try render(200, .thread(column: column), dim: 0, dark: false) == render(200, .plain, dim: 0, dark: false))
        #expect(TextDim.share(0.3, at: 0) == 1)
        #expect(TextDim.pictureBound(0.4, groundY: 0.01, dark: true, at: 0) == nil)
    }

    @Test(arguments: [true, false]) func strengthGrowsWithThePosition(dark: Bool) throws {
        let groundY = dark ? 0.003 : 0.92
        let b = try #require(PictureInk.textBound(text, dark: true))
        let base = dark ? b : 0.45
        var lastBound = dark ? 1.0 : 0.0, lastShare = 1.0, lastBlur = -1
        for p in 1...100 {
            let bound = try #require(TextDim.pictureBound(base, groundY: groundY, dark: dark, at: p))
            #expect(dark ? bound <= lastBound : bound >= lastBound, "bound at \(p)")
            // Close to the ground at the strong end, never past it.
            #expect(dark ? bound > groundY : bound < groundY)
            lastBound = bound
            let share = TextDim.share(0.3, at: p)
            #expect(share <= lastShare && share > 0, "share at \(p)")
            lastShare = share
            let blur = TextDim.blurDim(at: p)
            #expect(blur >= lastBlur)
            lastBlur = blur
        }
        #expect(abs(TextDim.share(0.3, at: 100) - 0.036) < 1e-9)
        // Rendered, the column's cells darken (dark) as the position grows.
        func columnLight(_ dim: Int) throws -> Double {
            let px = try render(200, .thread(column: column), dim: dim)
            var sum = 0.0
            for y in 0..<h { for x in 150..<330 { let i = (y * w + x) * 4; sum += Double(px[i]) + Double(px[i + 1]) + Double(px[i + 2]) } }
            return sum
        }
        if dark {
            let lights = try [0, 35, 70, 100].map(columnLight)
            #expect(zip(lights, lights.dropFirst()).allSatisfy { $0.1 < $0.0 }, "\(lights)")
        }
    }

    /// The flower's mask deepens with the position and keeps its falloff: far from the column it stays full.
    @Test func flowerMaskDeepens() {
        let p = LotusArt.Placement(width: 400, height: 40, centreX: 200, centreY: 60, radius: 200)
        var last = Int.max
        for dim in [10, 35, 70, 100] {
            let m = LotusArt.columnMask(p, column: 450...750, cap: DitherArtView.flowerShare(0.3, dim: dim),
                                        keep: DitherArtView.flowerShare(LotusArt.columnKeep, dim: dim), dark: true)
            let over = (0..<p.height).reduce(0) { $0 + Int(m[$1 * p.width + 200]) }
            #expect(over < last, "\(dim)")
            last = over
            #expect((0..<p.height).allSatisfy { m[$0 * p.width] == 255 })
        }
    }

    /// Blur's saved value comes back at the position the row shows.
    @Test func blurRoundTrips() {
        for dim in stride(from: 0, through: 90, by: 5) {
            #expect(abs(TextDim.blurDim(at: TextDim.position(blurDim: dim)) - dim) <= 1, "\(dim)")
        }
    }
}
