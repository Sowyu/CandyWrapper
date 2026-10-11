import AppKit
import Testing
@testable import DesignSystem
import T3Store

@MainActor
struct LabelClockTests {
    /// Requests due in the same wall-clock second share one tick; views that can't be seen wait.
    @Test func roundsToWholeSecondsAndSkipsHiddenViews() {
        let clock = LabelClock()
        clock.now = { 100.25 }
        let a = NSView(), b = NSView()
        clock.schedule(a, in: 0.5) {}
        clock.schedule(b, in: 0.7) {}
        #expect(clock.due(for: a) == Date(timeIntervalSince1970: 101))
        #expect(clock.due(for: b) == Date(timeIntervalSince1970: 101))
        clock.schedule(a, in: 1.9) {}
        #expect(clock.due(for: a) == Date(timeIntervalSince1970: 103))
        // Neither view is in a window, so nothing fires even when due.
        var fired = 0
        clock.schedule(a, in: 0) { fired += 1 }
        clock.now = { 200 }
        clock.visibilityChanged()
        #expect(fired == 0)
        #expect(clock.due(for: a) != nil)
        clock.cancel(a)
        #expect(clock.due(for: a) == nil)
        #expect(!LabelClock.canSee(a))
    }

    /// Labels wake when their text changes: each second below the unit change, then less often.
    @Test func elapsedLabelsWaitForTheirTextToChange() {
        #expect(ThreadRelationships.msUntilElapsedChanges(4_300, compact: false) == 700)
        #expect(ThreadRelationships.msUntilElapsedChanges(3_599_400, compact: false) == 600)
        #expect(ThreadRelationships.msUntilElapsedChanges(3_600_000 + 15_000, compact: false) == 45_000)
        #expect(ThreadRelationships.msUntilElapsedChanges(59_500, compact: true) == 500)
        #expect(ThreadRelationships.msUntilElapsedChanges(61_000, compact: true) == 59_000)
        #expect(ThreadRelationships.msUntilElapsedChanges(3_600_000, compact: true) == 360_000)
        #expect(ThreadRelationships.msUntilElapsedChanges(36_000_000 + 1_000, compact: true) == 3_599_000)
        // The texts really do stay put until then.
        for (ms, compact) in [(3_615_000, false), (61_000, true), (3_700_000, true)] as [(Int64, Bool)] {
            let wait = ThreadRelationships.msUntilElapsedChanges(Int64(ms), compact: compact)
            let text = { (m: Int64) in compact ? ThreadRelationships.compactElapsed(seconds: Double(m) / 1000)
                                               : ThreadRelationships.elapsed(seconds: Double(m) / 1000) }
            #expect(text(ms) == text(ms + wait - 1))
            #expect(text(ms) != text(ms + wait))
        }
    }
}
