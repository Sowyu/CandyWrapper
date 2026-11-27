import AppKit
import Testing
@testable import DesignSystem

/// A label shapes its text once per change of what it is shaped from, not on every draw: a user's sample
/// (2026-11-27) spent two thirds of `LabelView.draw` in `CTLineCreateWithAttributedString` on unchanged text.
@MainActor
struct LabelShapeCacheTests {
    private func render(_ label: LabelView) -> Data? {
        guard let rep = label.bitmapImageRepForCachingDisplay(in: label.bounds) else { return nil }
        label.cacheDisplay(in: label.bounds, to: rep)
        return rep.tiffRepresentation
    }

    @Test func redrawsWithoutAChangeShapeNothing() {
        let label = LabelView("Fix the sidebar's working rows", font: DSFont.ui(13))
        label.frame = NSRect(x: 0, y: 0, width: 120, height: 18)
        _ = render(label)
        let first = label.shapesForTesting
        #expect(first == 1)
        for _ in 0..<5 { _ = render(label) }
        #expect(label.shapesForTesting == first)
        // A new width refits the kept line without shaping it again.
        label.frame.size.width = 90
        _ = render(label)
        #expect(label.shapesForTesting == first)
        label.color = .systemRed
        _ = render(label)
        #expect(label.shapesForTesting == first + 1)
        label.text = "Another title"
        _ = render(label)
        #expect(label.shapesForTesting == first + 2)
    }

    @Test func keptLineDrawsTheSamePixels() {
        func make() -> LabelView {
            let label = LabelView("A long thread title that truncates at the end", font: DSFont.ui(13))
            label.frame = NSRect(x: 0, y: 0, width: 140, height: 18)
            return label
        }
        let kept = make()
        _ = render(kept)
        kept.frame.size.width = 100
        _ = render(kept)
        kept.frame.size.width = 140
        let fresh = make()
        #expect(render(kept) == render(fresh))
        #expect(kept.shapesForTesting == 1)
    }
}
