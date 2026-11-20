import AppKit
import Testing
@testable import Features

/// T3 4928 Sidebar.shiftGuard.ts (#23517): a press on a row that just slid under the pointer is dropped.
@MainActor @Suite struct SidebarShiftGuardTests {
    func rows(_ order: [String]) -> [String: (top: CGFloat, height: CGFloat)] {
        Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, (CGFloat($0) * 83, 82)) })
    }

    @Test func pressOnARowThatJustSlidIsDropped() {
        let guard_ = SidebarShiftGuard()
        guard_.update(tops: rows(["a", "b", "c"]), now: 10)
        // A thread arrives on top while the user isn't touching anything: every row slides down a row.
        guard_.update(tops: rows(["new", "a", "b", "c"]), now: 20)
        #expect(guard_.dropsPress(on: "a", at: 20.3))
        #expect(guard_.holdingDrop)
        #expect(guard_.releaseDrop()) // its release is swallowed too
        #expect(!guard_.holdingDrop)
        // After 500ms the row takes presses again.
        #expect(!guard_.dropsPress(on: "a", at: 20.6))
        #expect(!guard_.releaseDrop())
    }

    @Test func movesTheUserCausedKeepPresses() {
        let guard_ = SidebarShiftGuard()
        guard_.update(tops: rows(["a", "b", "c"]), now: 10)
        // Settle on "a" at 20.0: the rows under it slide up, and the next press lands where the user aims.
        #expect(!guard_.dropsPress(on: "a", at: 20))
        guard_.update(tops: rows(["b", "c"]), now: 20.2)
        #expect(!guard_.dropsPress(on: "b", at: 20.3))
        // Typing in a field doesn't count; the list only notes keys that can move rows.
        guard_.noteInput(at: 30)
        guard_.update(tops: rows(["c", "b"]), now: 30.1)
        #expect(!guard_.dropsPress(on: "c", at: 30.2))
    }

    @Test func nudgesUnderHalfARowAndTheFirstFillDontCount() {
        let guard_ = SidebarShiftGuard()
        guard_.update(tops: rows(["a", "b"]), now: 10) // filling from empty
        #expect(!guard_.dropsPress(on: "a", at: 10.1))
        var nudged = rows(["a", "b"])
        nudged["b"] = (83 + 40, 82) // under half of 82
        guard_.update(tops: nudged, now: 20)
        #expect(!guard_.dropsPress(on: "b", at: 20.1))
    }

    @Test func aLaterOwnMoveClearsTheMark() {
        let guard_ = SidebarShiftGuard()
        guard_.update(tops: rows(["a", "b"]), now: 10)
        guard_.update(tops: rows(["b", "a"]), now: 20)
        guard_.noteInput(at: 20.1)
        guard_.update(tops: rows(["a", "b"]), now: 20.2)
        #expect(!guard_.dropsPress(on: "a", at: 20.3))
    }
}
