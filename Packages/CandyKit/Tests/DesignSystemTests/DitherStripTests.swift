import AppKit
import Testing
@testable import DesignSystem

/// Redesign's section strip (the sidebar's Working, Snoozed and Settled headers).
struct DitherStripTests {
    /// Label ends and chevron limits from a narrow sidebar up to a wide one, at whole and half points.
    static let cases: [(labelEnd: CGFloat, limit: CGFloat)] = [
        (58, 72), (58, 120), (66.5, 180), (71, 232), (80.25, 252), (58, 400), (120, 124), (0, 8),
    ]

    @Test(arguments: cases.indices) func neverReachesTheLabelOrTheChevron(_ i: Int) {
        let c = Self.cases[i]
        let span = DitherStrip.span(labelEnd: c.labelEnd, limit: c.limit)
        if span.count > 0 {
            #expect(span.minX >= c.labelEnd + DitherStrip.gap)
            #expect(span.maxX <= c.limit)
        }
        let grid = DitherStrip.grid(span)
        for x in 0..<grid.width { for y in 0..<grid.height where grid[x, y] != 0 {
            let left = span.minX + CGFloat(x) * DitherStrip.cell
            #expect(left >= c.labelEnd + DitherStrip.gap && left + DitherStrip.cell <= c.limit)
        } }
    }

    @Test func sitsOnTheLatticeAndRendersTheSameEveryTime() {
        let span = DitherStrip.span(labelEnd: 66.5, limit: 232)
        #expect(span.minX.truncatingRemainder(dividingBy: DitherStrip.cell) == 0)
        #expect(DitherStrip.grid(span) == DitherStrip.grid(span))
        #expect(DitherStrip.mask(span)?.width == span.count && DitherStrip.mask(span)?.height == DitherStrip.rows)
    }

    @Test func denseAtTheLeftAndGoneBeforeTheEnd() {
        let span = DitherStrip.Span(first: 40, count: 90)
        let grid = DitherStrip.grid(span)
        func on(_ range: Range<Int>) -> Int { range.reduce(0) { n, x in n + (0..<grid.height).filter { grid[x, $0] != 0 }.count } }
        let third = span.count / 3
        #expect(on(0..<third) > on(third..<2 * third))
        #expect(on(third..<2 * third) > 0)
        // Nothing past the reach, so the strip ends about two thirds of the way across.
        let end = Int((Double(span.count) * DitherStrip.reach).rounded(.up))
        #expect(on(end..<span.count) == 0)
        // Two dot rows, 2pt squares 4pt apart: odd rows and odd columns stay empty.
        for x in 0..<grid.width { #expect(grid[x, 1] == 0) }
        for x in stride(from: (span.first & 1 == 0 ? 1 : 0), to: grid.width, by: 2) { #expect(grid[x, 0] == 0 && grid[x, 2] == 0) }
    }

    @Test func tooNarrowDrawsNothing() {
        #expect(DitherStrip.span(labelEnd: 120, limit: 124).count == 0)
        #expect(DitherStrip.mask(DitherStrip.span(labelEnd: 120, limit: 124)) == nil)
    }
}
