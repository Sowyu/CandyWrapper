import Testing
@testable import DesignSystem

/// The Snoozed and Settled line's motion (the user, 2026-11-21: "animate this thing in the line"): a wave on hover and
/// on a count change, a stretch on open and close, each ending on the resting strip and never between lattice cells.
@MainActor
struct DitherStripMotionTests {
    static let span = DitherStrip.Span(first: 40, count: 60)

    /// The dots of a frame at rest (no wave, no stretch) sit exactly where the resting mask has them.
    @Test func aStillFrameIsTheRestingStrip() {
        let f = DitherStrip.frame(Self.span, stretch: 1, wave: nil)
        let g = DitherStrip.grid(Self.span)
        let c = Int(DitherStrip.cell)
        for i in 0..<Self.span.count {
            for y in 0..<DitherStrip.rows {
                let on = f.alpha[(1 + y * c) * f.width + i * c] > 0
                #expect(on == (g[i, y] != 0), "cell \(i),\(y)")
            }
        }
        #expect(f.alpha[0..<f.width].allSatisfy { $0 == 0 }, "the headroom row is empty at rest")
        #expect(DitherStrip.grid(Self.span, stretch: 1) == g)
    }

    @Test func theWaveBrightensAndLiftsOnlyWhereItIs() {
        let mid = DitherStrip.frame(Self.span, stretch: 1, wave: 0.5)
        let rest = UInt8((DitherStrip.restAlpha * 255).rounded())
        #expect(mid.alpha.contains { $0 > rest }, "dots under the crest brighten")
        #expect(mid.alpha[0..<mid.width].contains { $0 > 0 }, "and lift 1pt into the headroom")
        // The dots far from the crest stay at the resting opacity.
        let start = DitherStrip.frame(Self.span, stretch: 1, wave: 0)
        #expect(start.alpha.filter { $0 > 0 }.allSatisfy { $0 == rest })
    }

    @Test func openingStretchesOutAndClosingGathersBack() {
        func lit(_ g: DitherFill.Grid) -> Int { g.cells.filter { $0 != 0 }.count }
        let rest = lit(DitherStrip.grid(Self.span))
        #expect(lit(DitherStrip.grid(Self.span, stretch: DitherStrip.openFrom)) < rest)
        #expect(lit(DitherStrip.grid(Self.span, stretch: DitherStrip.closeFrom)) > rest)
    }

    /// Both motions end: the frame function reports done, and the header then puts the resting mask back.
    @Test func motionsEndAndSayWhen() {
        var m = DitherStrip.Motion()
        m.waveStart = 10
        #expect(m.frame(now: 10.25, stretchDuration: 0.2)?.wave == 0.5)
        #expect(m.frame(now: 10.5, stretchDuration: 0.2) == nil)
        var s = DitherStrip.Motion()
        s.stretchStart = (10, DitherStrip.openFrom)
        let first = s.frame(now: 10, stretchDuration: 0.2)
        #expect(first?.stretch == DitherStrip.openFrom && first?.wave == nil)
        #expect(s.frame(now: 10.21, stretchDuration: 0.2) == nil)
    }
}
