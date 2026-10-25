import Foundation
import T3Protocol
import Testing
@testable import T3Store

extension ThreadNotificationTracker {
    /// A scan, then the completion grace running out.
    mutating func settle(environmentId: String, threads: [ThreadShell]) -> [ThreadNotificationEvent] {
        scan(environmentId: environmentId, threads: threads, nowMs: 0) + flush(nowMs: SidebarInboxReturnTracker.workingExitGraceMs)
    }
}

/// Cases from apps/web/src/components/ThreadNotificationCoordinator.test.tsx, .logic.test.ts and .badge.test.tsx.
struct ThreadNotificationsTests {
    /// ThreadNotificationCoordinator.logic.ts:56-70: completion waits 2 s and a continuation inside it cancels it.
    @Test func completionWaitsOutTheGrace() {
        var t = ThreadNotificationTracker()
        _ = t.scan(environmentId: "env-1", threads: [running()], nowMs: 0)
        #expect(t.scan(environmentId: "env-1", threads: [completed()], nowMs: 1_000).isEmpty)
        #expect(t.nextDueMs == 3_000)
        #expect(t.flush(nowMs: 2_999).isEmpty)
        #expect(t.flush(nowMs: 3_000).map(\.title) == ["Thread completed"])
        #expect(t.nextDueMs == nil)
        // The continuation starts within the grace: no completion for the run before it.
        _ = t.scan(environmentId: "env-1", threads: [running()], nowMs: 4_000)
        _ = t.scan(environmentId: "env-1", threads: [completed(run: "run-2", at: "2026-09-13T10:00:00.000Z")], nowMs: 5_000)
        var next = running()
        next.latestRunId = "run-3"
        next.activeRunId = "run-3"
        _ = t.scan(environmentId: "env-1", threads: [next], nowMs: 6_000)
        #expect(t.nextDueMs == nil && t.flush(nowMs: 10_000).isEmpty)
        // Attention notifies at once.
        next.pendingRuntimeRequest = PendingRuntimeRequestSummary(id: "q", kind: .userInput, createdAt: "2026-09-13T11:00:00.000Z")
        #expect(t.scan(environmentId: "env-1", threads: [next], nowMs: 11_000).map(\.title) == ["Input needed"])
    }

    private func running(_ id: String = "thread-1") -> ThreadShell {
        thread(id) {
            $0.title = "Fix the login form"
            $0.status = .running
            $0.latestRunId = "run-1"
            $0.activeRunId = "run-1"
            $0.latestRunCompletedAt = .null
        }
    }

    private func completed(_ id: String = "thread-1", run: String = "run-1", at: String = "2026-09-13T09:00:00.000Z") -> ThreadShell {
        thread(id) {
            $0.title = "Fix the login form"
            $0.status = .completed
            $0.latestRunId = RunId(run)
            $0.latestRunCompletedAt = .value(T3Timestamp(at))
            $0.updatedAt = T3Timestamp(at)
        }
    }

    @Test func modes() {
        #expect(ThreadNotificationMode.allCases.map(\.label) == ["Off", "Notifications only", "Sound only", "Notifications with sound"])
        #expect(ThreadNotificationMode.allCases.map(\.hasSound) == [false, false, true, true])
        #expect(ThreadNotificationMode.allCases.map(\.hasDesktopNotifications) == [false, true, false, true])
        #expect(ThreadNotificationMode(rawValue: "notifications-and-sound") == .notificationsAndSound)
    }

    @Test func completionNotifiesOnceAndNotOnFirstLoad() {
        var t = ThreadNotificationTracker()
        // First load: a finished thread is quiet.
        #expect(t.settle(environmentId: "env-1", threads: [completed()]).isEmpty)
        #expect(t.settle(environmentId: "env-1", threads: [running()]).isEmpty)
        let events = t.settle(environmentId: "env-1", threads: [completed(run: "run-2", at: "2026-09-13T10:00:00.000Z")])
        #expect(events.map(\.title) == ["Thread completed"])
        #expect(events.first?.threadTitle == "Fix the login form")
        #expect(events.first?.tag == "env-1:thread-1")
        #expect(events.first?.tone == .success && events.first?.icon == .circleCheck)
        // The same shell again: nothing new.
        #expect(t.settle(environmentId: "env-1", threads: [completed(run: "run-2", at: "2026-09-13T10:00:00.000Z")]).isEmpty)
    }

    /// ThreadNotificationCoordinator.tsx:154-160: a run the user stopped completes quietly.
    @Test func stoppedRunDoesNotAnnounceCompletion() {
        var t = ThreadNotificationTracker()
        _ = t.settle(environmentId: "env-1", threads: [running()])
        var stopped = completed(run: "run-2", at: "2026-09-13T10:00:00.000Z")
        stopped.latestRunStopRequested = true
        #expect(t.settle(environmentId: "env-1", threads: [stopped]).isEmpty)
        #expect(t.settle(environmentId: "env-1", threads: [completed(run: "run-3", at: "2026-09-13T11:00:00.000Z")]).map(\.title) == ["Thread completed"])
    }

    /// 0345e852ed: a compaction T3 Code started (`latestRunSilent`) completes quietly too.
    @Test func silentRunDoesNotAnnounceCompletion() {
        var t = ThreadNotificationTracker()
        _ = t.settle(environmentId: "env-1", threads: [running()])
        var compacted = completed(run: "run-2", at: "2026-09-13T10:00:00.000Z")
        compacted.latestRunSilent = true
        #expect(t.settle(environmentId: "env-1", threads: [compacted]).isEmpty)
    }

    @Test func reconnectDoesNotReplay() {
        var t = ThreadNotificationTracker()
        _ = t.settle(environmentId: "env-1", threads: [running()])
        t.reset(environmentId: "env-1")
        #expect(t.settle(environmentId: "env-1", threads: [completed()]).isEmpty)
    }

    @Test func attentionTitles() {
        let cases: [(String, (inout ThreadShell) -> Void)] = [
            ("Input needed", { $0.pendingRuntimeRequest = PendingRuntimeRequestSummary(id: "q", kind: .userInput, createdAt: "2026-09-13T09:00:00.000Z") }),
            ("Approval needed", { $0.pendingRuntimeRequest = PendingRuntimeRequestSummary(id: "q", kind: .command, createdAt: "2026-09-13T09:00:00.000Z") }),
            ("Thread failed", { $0.status = .failed; $0.activeRunId = nil; $0.lastErrorClass = .providerError }),
            ("Usage limit reached", { $0.status = .failed; $0.activeRunId = nil; $0.lastErrorClass = .usageLimit }),
        ]
        for (title, edit) in cases {
            var t = ThreadNotificationTracker()
            _ = t.settle(environmentId: "env-1", threads: [running()])
            var next = running()
            edit(&next)
            let events = t.settle(environmentId: "env-1", threads: [next])
            #expect(events.map(\.title) == [title])
            #expect(events.first?.kind == .input)
            // Still the same attention: no repeat.
            next.updatedAt = "2026-09-13T11:00:00.000Z"
            #expect(t.settle(environmentId: "env-1", threads: [next]).isEmpty)
        }
    }

    @Test func failedTurnOfAReadyThreadReadsAsFailed() {
        var t = ThreadNotificationTracker()
        _ = t.settle(environmentId: "env-1", threads: [running()])
        // `shellRuntime` is nil without a run or provider thread, so the status is ready; the failed run decides.
        var failed = running()
        failed.status = .failed
        failed.activeRunId = nil
        let events = t.settle(environmentId: "env-1", threads: [failed])
        #expect(events.map(\.title) == ["Thread failed"])
        #expect(events.first?.tone == .error && events.first?.icon == .circleAlert)
    }

    @Test func awaitedMonitorHoldsCompletionButADevServerDoesNot() {
        var t = ThreadNotificationTracker()
        _ = t.settle(environmentId: "env-1", threads: [running()])
        var watching = completed()
        watching.pendingBackgroundTasks = [PendingBackgroundTask(taskId: "watch", kind: .monitor, awaited: true)]
        #expect(t.settle(environmentId: "env-1", threads: [watching]).isEmpty)
        watching.pendingBackgroundTasks = [PendingBackgroundTask(taskId: "watchdog", kind: .monitor)]
        #expect(!SidebarModel.backgroundWorkHoldsCompletion(watching.pendingBackgroundTasks))
        var dev = completed()
        dev.pendingBackgroundTasks = [PendingBackgroundTask(taskId: "dev", kind: .command)]
        #expect(t.settle(environmentId: "env-1", threads: [dev]).map(\.title) == ["Thread completed"])
    }

    @Test func archivedAndSubagentThreadsStayQuiet() {
        var t = ThreadNotificationTracker()
        var sub = running("sub")
        sub.lineage.relationshipToParent = .subagent
        _ = t.settle(environmentId: "env-1", threads: [running(), sub])
        var archived = completed()
        archived.archivedAt = "2026-09-13T09:00:00.000Z"
        var subDone = completed("sub")
        subDone.lineage.relationshipToParent = .subagent
        #expect(t.settle(environmentId: "env-1", threads: [archived, subDone]).isEmpty)
    }

    @Test func environmentsAreSeparate() {
        var t = ThreadNotificationTracker()
        _ = t.settle(environmentId: "env-1", threads: [running()])
        #expect(t.settle(environmentId: "env-2", threads: [completed()]).isEmpty)
        #expect(t.settle(environmentId: "env-1", threads: [completed()]).map(\.environmentId) == ["env-1"])
    }

    @Test func routing() {
        let event = ThreadNotificationEvent(environmentId: "env-1", threadId: "thread-1", threadTitle: "T", kind: .completion, status: .ready)
        func route(_ mode: ThreadNotificationMode, inApp: Bool = true, focused: Bool = true, open: (String, ThreadId)? = nil,
                   granted: Bool = true) -> ThreadNotificationRoute {
            ThreadNotificationRoute.route(event, mode: mode, inAppEnabled: inApp, focused: focused,
                                          openThread: open.map { (environmentId: $0.0, threadId: $0.1) }, permissionGranted: granted)
        }
        // A toast replaces the system popup and keeps the sound.
        #expect(route(.notificationsAndSound) == .init(sound: true, toast: true, system: false))
        // The open thread: nothing visible.
        #expect(route(.notifications, open: ("env-1", "thread-1")) == .init(sound: false, toast: false, system: false))
        // Same thread id on another environment still toasts.
        #expect(route(.off, open: ("env-2", "thread-1")) == .init(sound: false, toast: true, system: false))
        // In the background: the system notification, whatever the in-app switch says.
        #expect(route(.notifications, focused: false) == .init(sound: false, toast: false, system: true))
        #expect(route(.notifications, inApp: false, focused: false) == .init(sound: false, toast: false, system: true))
        #expect(route(.notifications, focused: false, granted: false) == .init(sound: false, toast: false, system: false))
        #expect(route(.sound, inApp: false) == .init(sound: true, toast: false, system: false))
    }

    @Test func badgeCountsThreadsAndClears() {
        var b = NotificationBadgeCount()
        #expect(b.add(tag: "env-1:a", environmentId: "env-1", windowFocused: false) == 1)
        #expect(b.add(tag: "env-1:a", environmentId: "env-1", windowFocused: false) == 1)  // a repeat replaces
        #expect(b.add(tag: "env-2:a", environmentId: "env-2", windowFocused: false) == 2)
        #expect(b.keep(environments: ["env-1"]) == ["env-2:a"])
        #expect(b.count == 1)
        #expect(b.clear() == ["env-1:a"])
        #expect(b.count == 0)
        _ = b.add(tag: "env-1:b", environmentId: "env-1", windowFocused: false)
        // A focused window clears instead of badging.
        #expect(b.add(tag: "env-1:c", environmentId: "env-1", windowFocused: true) == 0)
        #expect(b.count == 0)
    }
}
