import Foundation
import T3Protocol
import Testing
@testable import T3Store

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private func event(_ id: String, _ kind: OrchestratorEvent.Kind = .finished) -> OrchestratorEvent {
    OrchestratorEvent(threadId: ThreadId(id), title: id, kind: kind, permission: .free)
}
private func limited(_ run: String, at: Date, reset: Date?, text: String = "You've hit your weekly limit") -> ThreadShell {
    thread("orch") {
        $0.status = .failed
        $0.latestRunId = RunId(run)
        $0.latestRunCompletedAt = .value(T3Timestamp(at))
        $0.lastError = text
        $0.lastErrorClass = .usageLimit
        $0.usageLimitResetAt = reset.map { T3Timestamp($0) }
    }
}

@Suite struct OrchestratorLimitTests {
    /// Events that land while the provider is limited start no run. They go out once, as one message, at the reset.
    @Test func heldEventsGoOutOnceCombinedAfterTheReset() {
        var batch = OrchestratorEventBatch()
        let reset = now.addingTimeInterval(3 * 3600)
        #expect(batch.follow(limited("run-1", at: now, reset: reset), now: now) == nil)
        #expect(batch.holding(now: now))
        #expect(batch.add([event("a")], now: now.addingTimeInterval(60)) == reset)
        #expect(batch.add([event("b", .failed)], now: now.addingTimeInterval(1800)) == nil)
        #expect(batch.add([event("a")], now: now.addingTimeInterval(3600)) == nil)
        // The same failed run seen again moves nothing.
        #expect(batch.follow(limited("run-1", at: now, reset: reset), now: now.addingTimeInterval(3700)) == nil)
        #expect(batch.flush(now: now.addingTimeInterval(180)) == nil)
        #expect(batch.flush(now: reset.addingTimeInterval(-1)) == nil)
        let message = batch.flush(now: reset)
        #expect(message?.split(separator: "\n").count == 2)
        #expect(batch.flush(now: reset.addingTimeInterval(600)) == nil)
        #expect(batch.pending.isEmpty)
    }

    /// A batch already open when the limit hits moves to the reset instead of going out.
    @Test func anOpenBatchMovesToTheReset() {
        var batch = OrchestratorEventBatch()
        _ = batch.add([event("a")], now: now)
        let reset = now.addingTimeInterval(7200)
        #expect(batch.follow(limited("run-1", at: now, reset: reset), now: now.addingTimeInterval(10)) == reset)
        #expect(batch.flush(now: now.addingTimeInterval(120)) == nil)
        #expect(batch.flush(now: reset) != nil)
    }

    /// Without a reset time it tries again after 15 min, 30 min, then hourly, counted from each failure.
    @Test func backsOffWithoutAResetTime() {
        var batch = OrchestratorEventBatch()
        var t = now
        for (i, wait) in [15.0, 30, 60, 60].enumerated() {
            _ = batch.follow(limited("run-\(i)", at: t, reset: nil, text: "Rate limited"), now: t)
            #expect(batch.heldUntil == t.addingTimeInterval(wait * 60))
            t = t.addingTimeInterval(wait * 60 + 5)
        }
    }

    /// A run that ends well, as after you switch models, lifts the hold and what waited goes out now.
    @Test func aWorkingRunLiftsTheHold() {
        var batch = OrchestratorEventBatch()
        _ = batch.follow(limited("run-1", at: now, reset: now.addingTimeInterval(7200)), now: now)
        _ = batch.add([event("a")], now: now)
        let later = now.addingTimeInterval(600)
        #expect(batch.follow(thread("orch") { $0.status = .running }, now: later) == nil)
        #expect(batch.holding(now: later))
        #expect(batch.follow(thread("orch") { $0.status = .completed; $0.latestRunId = RunId("run-2") }, now: later) == later)
        #expect(!batch.holding(now: later))
        #expect(batch.flush(now: later) != nil)
    }

    /// A limit whose reset already passed holds nothing.
    @Test func aPastLimitHoldsNothing() {
        var batch = OrchestratorEventBatch()
        _ = batch.follow(limited("run-1", at: now.addingTimeInterval(-7200), reset: now.addingTimeInterval(-60)), now: now)
        #expect(!batch.holding(now: now))
        #expect(batch.add([event("a")], now: now) == now.addingTimeInterval(120))
    }

    @Test func readsTheResetFromTheText() throws {
        // 06:00 UTC on 2026-10-25, after Paris left summer time: 8pm there is 19:00 UTC.
        let after = try #require(ISO8601DateFormatter().date(from: "2026-10-25T06:00:00Z"))
        let reset = OrchestratorLimit.resetTime(in: "You've hit your weekly limit · resets 8pm (Europe/Paris)", after: after)
        #expect(reset == ISO8601DateFormatter().date(from: "2026-10-25T19:00:00Z"))
        // Past 8pm it's the next day's.
        let late = try #require(ISO8601DateFormatter().date(from: "2026-10-25T20:00:00Z"))
        #expect(OrchestratorLimit.resetTime(in: "resets 8pm (Europe/Paris)", after: late) == ISO8601DateFormatter().date(from: "2026-10-26T19:00:00Z"))
        #expect(OrchestratorLimit.resetTime(in: "resets 7:30am (UTC)", after: after) == ISO8601DateFormatter().date(from: "2026-10-25T07:30:00Z"))
        #expect(OrchestratorLimit.resetTime(in: "resets Oct 28, 8pm (UTC)", after: after) == ISO8601DateFormatter().date(from: "2026-10-28T20:00:00Z"))
        #expect(OrchestratorLimit.resetTime(in: "Overloaded", after: after) == nil)
        #expect(OrchestratorLimit.isLimit(nil, message: "You've hit your weekly limit · resets 8pm"))
        #expect(!OrchestratorLimit.isLimit(.transportError, message: "You've hit your weekly limit"))
    }
}
