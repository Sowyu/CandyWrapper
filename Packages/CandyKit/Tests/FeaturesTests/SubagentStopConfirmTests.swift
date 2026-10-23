import Foundation
import Testing
@testable import Features

/// Stop on a subagent strip row takes two clicks within three seconds; leaving, Esc or the timeout disarms it.
struct SubagentStopConfirmTests {
    @Test func firstClickArmsSecondStops() {
        var c = SubagentStopConfirm()
        let r101 = c.press("a", now: 10)
        #expect(r101 == .armed)
        #expect(c.armed == "a")
        let r102 = c.press("a", now: 12.9)
        #expect(r102 == .stop)
        #expect(c.armed == nil)
    }

    @Test func aLateSecondClickOnlyRearms() {
        var c = SubagentStopConfirm()
        _ = c.press("a", now: 10)
        let r103 = c.press("a", now: 13)
        #expect(r103 == .armed)
        let r104 = c.press("a", now: 14)
        #expect(r104 == .stop)
    }

    @Test func anotherRowArmsInstead() {
        var c = SubagentStopConfirm()
        _ = c.press("a", now: 10)
        let r105 = c.press("b", now: 10.5)
        #expect(r105 == .armed)
        #expect(c.armed == "b")
        let r106 = c.press("a", now: 11)
        #expect(r106 == .armed)
    }

    @Test func leavingEscAndTimeoutDisarm() {
        var c = SubagentStopConfirm()
        _ = c.press("a", now: 10)
        let r1 = c.cancel("b")
        #expect(!r1)
        #expect(c.armed == "a")
        let r2 = c.cancel("a")
        #expect(r2)
        let r107 = c.press("a", now: 10.2)
        #expect(r107 == .armed)
        let r3 = c.cancel()
        #expect(r3)
        let r4 = c.cancel()
        #expect(!r4)
        _ = c.press("a", now: 20)
        c.expire(now: 22)
        #expect(c.armed == "a")
        c.expire(now: 23)
        #expect(c.armed == nil)
        let r108 = c.press("a", now: 23.1)
        #expect(r108 == .armed)
    }
}
