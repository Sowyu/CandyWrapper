import AppKit
import Testing
@testable import DesignSystem

/// #29018: a button can take rounder corners than its own radius, one corner at a time.
@MainActor struct ButtonCornerRadiiTests {
    @Test func masksOnlyTheCornersItRounds() throws {
        let button = ButtonView("Retry", variant: .ghost, size: .xs)
        button.frame = NSRect(x: 0, y: 0, width: 60, height: 24)
        #expect(button.cornerMaskPath() == nil)
        button.cornerRadii = (0, 12, 0, 0)
        button.layoutSubtreeIfNeeded()
        let path = try #require(button.cornerMaskPath())
        let box = path.boundingBoxOfPath
        // The top trailing corner is cut on a 12pt arc; the bottom trailing one only on the button's own radius.
        let topTrailing = CGPoint(x: box.maxX - 2, y: box.minY + 2), bottomTrailing = CGPoint(x: box.maxX - 2, y: box.maxY - 2)
        #expect(!path.contains(topTrailing))
        #expect(path.contains(bottomTrailing) == (ButtonView.Size.xs.metrics.radius < 2))
        #expect(path.contains(CGPoint(x: box.midX, y: box.midY)))
    }
}
