import Foundation
import Testing
@testable import Features

/// A thread that hangs or crashes the app on open must not reopen on the next launch.
@MainActor
struct LaunchGuardTests {
    func defaults() -> UserDefaults {
        let name = "LaunchGuardTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func aCleanQuitRestoresAsBefore() {
        let d = defaults()
        let first = LaunchGuard(defaults: d)
        first.begin(shiftHeld: false)
        #expect(first.restoresLastThread)
        first.willRestore("t1")
        first.end()
        #expect(d.object(forKey: LaunchGuard.runningKey) == nil && d.object(forKey: LaunchGuard.openingKey) == nil)
        let next = LaunchGuard(defaults: d)
        next.begin(shiftHeld: false)
        #expect(next.previous == .clean && next.restoresLastThread)
        #expect(next.takeNotice(title: "T") == nil)
    }

    @Test func aRunThatDiesWhileOpeningSkipsTheRestoreOnce() {
        let d = defaults()
        let first = LaunchGuard(defaults: d)
        first.begin(shiftHeld: false)
        first.willRestore("env/t1")
        first.shown("env/t1")
        // Killed before the settle timer fired: no end().
        let next = LaunchGuard(defaults: d)
        next.begin(shiftHeld: false)
        #expect(next.previous == .didNotFinishOpening("env/t1"))
        #expect(!next.restoresLastThread)
        #expect(next.takeNotice(title: "Fix the build") == "CandyWrapper did not finish opening \u{201C}Fix the build\u{201D} last time, so it started on a new thread.")
        #expect(next.takeNotice(title: "Fix the build") == nil, "the notice shows once")
        next.end()
        let third = LaunchGuard(defaults: d)
        third.begin(shiftHeld: false)
        #expect(third.restoresLastThread, "one skip, then back to normal")
    }

    @Test func anUncleanExitAfterOpeningSkipsTheRestoreOnce() {
        let d = defaults()
        let first = LaunchGuard(defaults: d)
        first.begin(shiftHeld: false)
        first.willRestore("t1")
        first.opened()
        #expect(d.object(forKey: LaunchGuard.openingKey) == nil)
        let next = LaunchGuard(defaults: d)
        next.begin(shiftHeld: false)
        #expect(next.previous == .quitUnexpectedly && !next.restoresLastThread)
        #expect(next.takeNotice(title: nil) == "CandyWrapper quit unexpectedly last time, so it started on a new thread.")
    }

    @Test func theSettleTimerClearsTheOpeningMarker() async {
        let d = defaults()
        let g = LaunchGuard(defaults: d, settle: 0.05)
        g.begin(shiftHeld: false)
        g.willRestore("t1")
        g.shown("other")
        try? await Task.sleep(for: .milliseconds(200))
        #expect(d.string(forKey: LaunchGuard.openingKey) == "t1", "another thread showing proves nothing")
        g.shown("t1")
        try? await Task.sleep(for: .milliseconds(200))
        #expect(d.string(forKey: LaunchGuard.openingKey) == nil)
        #expect(d.object(forKey: LaunchGuard.runningKey) != nil)
    }

    @Test func shiftSkipsTheRestoreWithoutANotice() {
        let g = LaunchGuard(defaults: defaults())
        g.begin(shiftHeld: true)
        #expect(!g.restoresLastThread)
        #expect(g.takeNotice(title: "T") == nil)
    }

    /// A second instance quits after handing off and never calls begin(), so its quit leaves the first one's marker.
    @Test func aGuardThatNeverBeganLeavesTheMarkers() {
        let d = defaults()
        LaunchGuard(defaults: d).begin(shiftHeld: false)
        LaunchGuard(defaults: d).end()
        #expect(d.object(forKey: LaunchGuard.runningKey) != nil)
    }
}
