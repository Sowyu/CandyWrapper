import Foundation
import Testing
import T3Protocol
@testable import T3Store

/// The offline settle and snooze outbox (#24917, threadTriageOutbox.ts at 5258).
@Suite("Thread triage outbox")
struct ThreadTriageOutboxTests {
    static let env = "env-1"
    static let at: T3Timestamp = "2026-11-25T10:00:00.000Z"
    static var idle: ThreadShell { thread("t1") { $0.status = .idle; $0.settledOverride = nil; $0.pinnedAt = nil } }

    @Test func aSettleWaitsAndShowsSettledWithPending() throws {
        var outbox = ThreadTriageOutbox()
        let q1 = outbox.queue(.settle, thread: Self.idle, environmentId: Self.env, commandId: "c1", now: Self.at)
        #expect(q1)
        #expect(outbox.pendingThreads(environmentId: Self.env) == ["t1"])
        #expect(outbox.pendingThreads(environmentId: "other").isEmpty)
        let shown = outbox.apply(ShellSnapshot(schemaVersion: 1, snapshotSequence: 3, threads: [Self.idle], projects: []), environmentId: Self.env)
        #expect(shown.threads.first?.settledOverride == .settled)
        #expect(shown.threads.first?.settledAt == Self.at)
    }

    @Test func aChangeThatWouldDoNothingIsNotQueued() {
        var outbox = ThreadTriageOutbox()
        let running = thread("t1") { $0.status = .running }
        let q2 = outbox.queue(.settle, thread: running, environmentId: Self.env, now: Self.at)
        #expect(!q2)
        #expect(outbox.entries.isEmpty)
    }

    @Test func oneChangePerThreadAndASnoozeNeverReplacesASettle() {
        var outbox = ThreadTriageOutbox()
        let wake = "2026-11-26T10:00:00.000Z"
        let q3 = outbox.queue(.snooze(until: wake), thread: Self.idle, environmentId: Self.env, commandId: "s", now: Self.at)
        #expect(q3)
        let q4 = outbox.queue(.settle, thread: Self.idle, environmentId: Self.env, commandId: "c", now: Self.at)
        #expect(q4)
        #expect(outbox.entries.map(\.commandId) == ["c"])
        let q5 = outbox.queue(.snooze(until: wake), thread: Self.idle, environmentId: Self.env, commandId: "s2", now: Self.at)
        #expect(!q5)
        #expect(outbox.entries.map(\.commandId) == ["c"])
    }

    @Test func aLiveShellThatStillShowsTheThreadAsSeenDrainsIt() {
        var outbox = ThreadTriageOutbox()
        outbox.queue(.settle, thread: Self.idle, environmentId: Self.env, commandId: "c1", now: Self.at)
        // A rename on the server does not count as a conflict.
        var renamed = Self.idle
        renamed.title = "Renamed elsewhere"
        let plan = outbox.replay(ShellSnapshot(schemaVersion: 1, snapshotSequence: 4, threads: [renamed], projects: []), environmentId: Self.env)
        #expect(plan.send.map(\.commandId) == ["c1"])
        #expect(plan.drop.isEmpty)
        outbox.forget(commandId: "c1")
        #expect(outbox.entries.isEmpty)
    }

    @Test func aThreadThatMovedOnTheServerWinsOverTheQueuedChange() {
        var outbox = ThreadTriageOutbox()
        outbox.queue(.settle, thread: Self.idle, environmentId: Self.env, commandId: "c1", now: Self.at)
        var worked = Self.idle
        worked.itemCount += 2
        let moved = outbox.replay(ShellSnapshot(schemaVersion: 1, snapshotSequence: 5, threads: [worked], projects: []), environmentId: Self.env)
        #expect(moved.send.isEmpty && moved.drop.map(\.commandId) == ["c1"])
        // Settled elsewhere already, or gone: dropped too.
        var settled = Self.idle
        settled.settledOverride = .settled
        settled.settledAt = Self.at
        #expect(outbox.replay(ShellSnapshot(schemaVersion: 1, snapshotSequence: 5, threads: [settled], projects: []), environmentId: Self.env).drop.count == 1)
        #expect(outbox.replay(ShellSnapshot(schemaVersion: 1, snapshotSequence: 5, threads: [], projects: []), environmentId: Self.env).drop.count == 1)
    }

    @Test func undoBeforeTheSyncCancelsOnlyThatKind() {
        var outbox = ThreadTriageOutbox()
        outbox.queue(.settle, thread: Self.idle, environmentId: Self.env, now: Self.at)
        let q6 = outbox.cancel(environmentId: Self.env, threadId: "t1", type: "snooze")
        #expect(!q6)
        let q7 = outbox.cancel(environmentId: Self.env, threadId: "t1", type: "settle")
        #expect(q7)
        #expect(outbox.entries.isEmpty)
    }

    @Test func waitingChangesSurviveARelaunchInTheirOwnDefaults() throws {
        let suite = "ThreadTriageOutboxTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var outbox = ThreadTriageOutbox()
        outbox.queue(.snooze(until: "2026-11-26T10:00:00.000Z"), thread: Self.idle, environmentId: Self.env, commandId: "s1", now: Self.at)
        outbox.save(defaults)
        let relaunched = ThreadTriageOutbox.load(defaults)
        #expect(relaunched == outbox)
        #expect(relaunched.entries.first?.action == .snooze(until: "2026-11-26T10:00:00.000Z"))
        ThreadTriageOutbox().save(defaults)
        #expect(defaults.data(forKey: ThreadTriageOutbox.defaultsKey) == nil)
        #expect(ThreadTriageOutbox.load(defaults).entries.isEmpty)
    }
}
