import AppKit
import Testing
@testable import DesignSystem

/// A wheel's line deltas become points; a trackpad's points pass through.
@MainActor struct ScrollDeltaTests {
    @Test func wheelLinesScaleTrackpadPointsDoNot() throws {
        let wheel = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 2, wheel2: 0, wheel3: 0))
        let w = try #require(NSEvent(cgEvent: wheel))
        #expect(!w.hasPreciseScrollingDeltas)
        #expect(w.scrollPointsY == w.scrollingDeltaY * NSEvent.wheelLine)
        let pad = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 7, wheel2: 0, wheel3: 0))
        let p = try #require(NSEvent(cgEvent: pad))
        #expect(p.hasPreciseScrollingDeltas)
        #expect(p.scrollPointsY == p.scrollingDeltaY)
    }
}
