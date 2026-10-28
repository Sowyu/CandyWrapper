import Foundation
import T3Protocol
import Testing
@testable import T3Store

/// ChatView's visit effect (ChatView.tsx:2938-3000) as `ThreadVisitTracker` ports it.
@Suite struct ThreadVisitsTests {
    let now: Int64 = T3Timestamp("2026-06-20T00:00:30.000Z").epochMs!

    @Test func serversWithoutVisitTrackingKeepALocalWatermark() {
        var shell = thread()
        shell.lastVisitedAt = .absent
        let tracker = ThreadVisitTracker()
        #expect(tracker.decide(shell, routeKey: "e:t", local: nil, nowMs: now) == .local(shell.updatedAt))
        #expect(tracker.decide(shell, routeKey: "e:t", local: shell.updatedAt, nowMs: now) == .none)
    }

    @Test func anUnseenCompletionPublishesAtOnceAndDedupes() {
        let shell = thread {
            $0.lastVisitedAt = .value("2026-06-19T23:00:00.000Z")
            $0.latestRunId = "run-1"
            $0.status = .completed
            $0.latestRunCompletedAt = .value("2026-06-20T00:00:00.000Z")
        }
        var tracker = ThreadVisitTracker()
        #expect(tracker.decide(shell, routeKey: "e:t", local: nil, nowMs: now) == .dispatch(shell.updatedAt, delayMs: 0))
        tracker.didDispatch(shell, routeKey: "e:t", nowMs: now)
        // The echo has not landed yet: the same watermark is not sent twice.
        #expect(tracker.decide(shell, routeKey: "e:t", local: nil, nowMs: now + 50) == .none)
        tracker.reset()
        #expect(tracker.decide(shell, routeKey: "e:t", local: nil, nowMs: now + 50) == .dispatch(shell.updatedAt, delayMs: 0))
    }

    @Test func switchingRoutesAndRapidReopensStartWithoutThePreviousThrottle() {
        let shell = thread {
            $0.lastVisitedAt = .value("2026-06-19T23:00:00.000Z")
            $0.status = .running
            $0.latestRunCompletedAt = .null
        }
        var tracker = ThreadVisitTracker()
        tracker.didDispatch(shell, routeKey: "a:t", nowMs: now)
        #expect(tracker.decide(shell, routeKey: "b:t", local: nil, nowMs: now + 50) == .dispatch(shell.updatedAt, delayMs: 0))
        tracker.reset()
        #expect(tracker.decide(shell, routeKey: "a:t", local: nil, nowMs: now + 100) == .dispatch(shell.updatedAt, delayMs: 0))
        tracker.didDispatch(shell, routeKey: "a:t", nowMs: now + 100)
        var newer = shell
        newer.updatedAt = "2026-06-20T00:00:31.000Z"
        #expect(tracker.decide(newer, routeKey: "a:t", local: nil, nowMs: now + 200) == .dispatch(newer.updatedAt, delayMs: 9_900))
    }

    @Test func midTurnActivityRidesATrailingThrottle() {
        var shell = thread {
            $0.lastVisitedAt = .value("2026-06-19T23:00:00.000Z")
            $0.latestRunId = "run-1"
            $0.status = .running
            $0.latestRunCompletedAt = .null
        }
        var tracker = ThreadVisitTracker()
        #expect(tracker.decide(shell, routeKey: "e:t", local: nil, nowMs: now) == .dispatch(shell.updatedAt, delayMs: 0))
        tracker.didDispatch(shell, routeKey: "e:t", nowMs: now)
        shell.updatedAt = "2026-06-20T00:00:31.000Z"
        #expect(tracker.decide(shell, routeKey: "e:t", local: nil, nowMs: now + 4_000) == .dispatch(shell.updatedAt, delayMs: 6_000))
        // A visit at or after the last activity sends nothing.
        shell.lastVisitedAt = .value(shell.updatedAt)
        #expect(tracker.decide(shell, routeKey: "e:t", local: nil, nowMs: now + 4_000) == .none)
    }
}
