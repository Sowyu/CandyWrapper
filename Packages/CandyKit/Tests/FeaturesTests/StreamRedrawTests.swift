import AppKit
import Testing
@testable import DesignSystem
@testable import Features

/// WP8.3: a streaming answer redraws only its changed tail, and deltas are paced per frame.
@MainActor
struct StreamRedrawTests {
    @Test func growingAnswerRedrawsOnlyItsTail() throws {
        let width: CGFloat = 600
        let old = MarkdownDocument(parsing: "First paragraph, done.\n\nSecond paragraph, done.\n\nThird is stream")
        let new = MarkdownDocument(parsing: "First paragraph, done.\n\nSecond paragraph, done.\n\nThird is streaming along.\n\nFourth")
        let before = MarkdownLayout(document: old, width: width), after = MarkdownLayout(document: new, width: width)
        #expect(before.blockTops.count == 3 && after.blockTops.count == 4)
        let rect = try #require(MarkdownView.changedRect(previous: before, oldBlocks: old.blocks, current: after, blocks: new.blocks))
        #expect(rect.minY == max(0, after.blockTops[2] - 8))
        #expect(rect.maxY >= after.height)
        #expect(rect.minY > after.blockTops[1])
    }

    @Test func movedPrefixRedrawsEverything() {
        let width: CGFloat = 600
        let old = MarkdownDocument(parsing: "One.\n\nTwo.")
        let new = MarkdownDocument(parsing: "One, now long enough to wrap onto a second line at this width, which moves every block after it down the page.\n\nTwo.")
        let rect = MarkdownView.changedRect(previous: MarkdownLayout(document: old, width: width), oldBlocks: old.blocks,
                                            current: MarkdownLayout(document: new, width: width), blocks: new.blocks)
        // The first block changed, so the rect starts at the top.
        #expect(rect?.minY == 0)
        let narrower = MarkdownView.changedRect(previous: MarkdownLayout(document: old, width: width), oldBlocks: old.blocks,
                                                current: MarkdownLayout(document: old, width: 300), blocks: old.blocks)
        #expect(narrower == nil)
    }

    @Test func pacerWaitsOutTheFrame() {
        #expect(FramePacer.delay(now: 10, last: -.infinity, interval: 1.0 / 60) == 0)
        #expect(FramePacer.delay(now: 10, last: 9.9, interval: 1.0 / 60) == 0)
        #expect(abs(FramePacer.delay(now: 10, last: 9.99, interval: 1.0 / 30) - (1.0 / 30 - 0.01)) < 1e-9)
    }

    @Test func constrainedPower() {
        #expect(!PowerState.constrained(lowPower: false, battery: false, thermal: .fair))
        #expect(PowerState.constrained(lowPower: true, battery: false, thermal: .nominal))
        #expect(PowerState.constrained(lowPower: false, battery: true, thermal: .nominal))
        #expect(PowerState.constrained(lowPower: false, battery: false, thermal: .serious))
    }

    /// Unchanged colors compare equal, so label setters skip the redraw.
    @Test func themedColorsAreShared() {
        #expect(Themed.color(\.foreground) === Themed.color(\.foreground))
        #expect(Themed.color(\.foreground, 0.5) !== Themed.color(\.foreground))
    }
}
