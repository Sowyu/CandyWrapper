import Foundation
import T3Protocol
import Testing
@testable import T3Store

private typealias S = SidebarModel

private let runtime = ThreadRuntimeSummary(status: .running, updatedAt: "2026-03-09T10:00:00.000Z")

private func latestRun(
    startedAt: T3Timestamp? = "2026-03-09T10:00:00.000Z", completedAt: T3Timestamp? = "2026-03-09T10:05:00.000Z"
) -> ThreadRunSummary {
    ThreadRunSummary(runId: "turn-1", status: .completed, requestedAt: "2026-03-09T10:00:00.000Z",
                     startedAt: startedAt, completedAt: completedAt)
}

private func status(approvals: Bool = false, input: Bool = false, _ runtime: ThreadRuntimeSummary?) -> SidebarThreadStatus {
    S.resolveSidebarThreadStatus(hasPendingApprovals: approvals, hasPendingUserInput: input, runtime: runtime)
}

private func pill(
    approvals: Bool = false, input: Bool = false, mode: InteractionMode = .plan, plan: Bool = false,
    run: ThreadRunSummary? = nil, runtime: ThreadRuntimeSummary? = ThreadRuntimeSummary(status: .running, activeRunId: "turn-1"),
    visited: T3Timestamp? = nil, tasks: [PendingBackgroundTask] = []
) -> ThreadStatusPill? {
    S.resolveThreadStatusPill(hasPendingApprovals: approvals, hasPendingUserInput: input, interactionMode: mode,
                              hasActionableProposedPlan: plan, latestRun: run, runtime: runtime,
                              lastVisitedAt: visited, pendingBackgroundTasks: tasks)
}

/// Ports of apps/web/src/components/Sidebar.logic.test.ts.
@Suite struct SidebarLogicPortTests {
    /// Sidebar.logic.ts:894-921 and 1061-1154, models.ts:226-263 (3473): a turn blocked on another
    /// thread waits, and an async question keeps a working thread working.
    @Test func threadWaitAndAsyncQuestions() {
        #expect(S.resolveSidebarThreadStatus(hasPendingApprovals: false, hasPendingUserInput: false, runtime: runtime, blockedOnThreadWait: true) == .waiting)
        #expect(status(runtime) == .working)
        let blocked = S.resolveThreadStatusPill(hasPendingApprovals: false, hasPendingUserInput: false, interactionMode: .default,
                                                hasActionableProposedPlan: false, latestRun: nil, runtime: runtime,
                                                lastVisitedAt: nil, pendingBackgroundTasks: [], blockedOnThreadWait: true)
        #expect(blocked == ThreadStatusPill(label: .waiting, pulse: false))
        let question = PendingRuntimeRequestSummary(id: "request-1", kind: .userInput, createdAt: "2026-03-09T10:00:00.000Z", blocking: false)
        let working = sidebarThread { $0.status = .running; $0.latestRunId = "run-1"; $0.activeRunId = "run-1"; $0.pendingRuntimeRequest = question }
        #expect(!working.hasPendingUserInput)
        #expect(S.resolveSidebarThreadStatus(working) == .working)
        let settled = sidebarThread { $0.status = .completed; $0.latestRunId = "run-1"; $0.pendingRuntimeRequest = question }
        #expect(settled.hasPendingUserInput)
        var blocking = question
        blocking.blocking = nil
        #expect(sidebarThread { $0.status = .running; $0.latestRunId = "run-1"; $0.pendingRuntimeRequest = blocking }.hasPendingUserInput)
    }

    @Test func sectionPrecedence() {
        #expect(S.resolveSidebarThreadSection(snoozed: false, settled: false, pinned: true) == .pinned)
        #expect(S.resolveSidebarThreadSection(snoozed: true, settled: true, pinned: true) == .snoozed)
        #expect(S.resolveSidebarThreadSection(snoozed: false, settled: true, pinned: true) == .settled)
    }

    @Test func visibleThreadsAreTopLevelUnarchivedAndInScope() {
        let root = sidebarThread("thread-parent") { $0.projectId = "project-visible" }
        let subagent = sidebarThread("thread-subagent") {
            $0.projectId = "project-visible"
            $0.lineage = ThreadLineage(parentThreadId: "thread-parent", relationshipToParent: .subagent, rootThreadId: "thread-parent")
        }
        let fork = sidebarThread("thread-fork") {
            $0.projectId = "project-visible"
            $0.lineage = ThreadLineage(parentThreadId: "thread-parent", relationshipToParent: .fork, rootThreadId: "thread-parent")
        }
        let archived = sidebarThread("thread-archived") { $0.projectId = "project-visible"; $0.archivedAt = "2026-01-02T00:00:00.000Z" }
        let otherProject = sidebarThread("thread-other-project") { $0.projectId = "project-other" }
        let visible = S.filterSidebarV2VisibleThreads([root, subagent, fork, archived, otherProject], scopedProjectIds: ["project-visible"])
        #expect(visible.map(\.id) == ["thread-parent", "thread-fork"])
        #expect(S.isSidebarSubagentThread(subagent.shell) && !S.isSidebarSubagentThread(root.shell))
    }

    @Test func forkParent() {
        let lineage = ThreadLineage(parentThreadId: "thread-fallback-parent", relationshipToParent: .fork, rootThreadId: "thread-parent")
        let runFork = thread { $0.lineage = lineage; $0.forkedFrom = ForkedFrom(type: "run", threadId: "thread-parent", runId: "run-1") }
        let lineageFork = thread { $0.lineage = lineage }
        #expect(S.getSidebarForkParentThreadId(runFork) == "thread-parent")
        #expect(S.getSidebarForkParentThreadId(lineageFork) == "thread-fallback-parent")
        #expect(S.getSidebarForkParentThreadId(thread()) == nil)
    }

    @Test func unseenCompletion() {
        #expect(S.hasUnseenCompletion(latestRun: latestRun(), lastVisitedAt: "2026-03-09T10:04:00.000Z"))
        #expect(!S.hasUnseenCompletion(latestRun: latestRun(), lastVisitedAt: nil))
    }

    @Test(arguments: [SidebarThreadStatus.working, .waiting])
    func recedesInactiveBusyThreads(_ status: SidebarThreadStatus) {
        #expect(S.shouldRecedeSidebarThread(status: status, isUnread: true, isWoke: true, isActive: false, isSelected: false))
    }

    @Test(arguments: [SidebarThreadStatus.ready, .approval, .input])
    func keepsUnreadThreadsProminent(_ status: SidebarThreadStatus) {
        #expect(!S.shouldRecedeSidebarThread(status: status, isUnread: true, isWoke: false, isActive: false, isSelected: false))
    }

    @Test func keepsActiveAndSelectedWorkingThreadsProminent() {
        #expect(!S.shouldRecedeSidebarThread(status: .working, isUnread: true, isWoke: true, isActive: true, isSelected: false))
        #expect(!S.shouldRecedeSidebarThread(status: .working, isUnread: true, isWoke: true, isActive: false, isSelected: true))
    }

    @Test(arguments: [false, true])
    func keepsInputThreadsProminent(_ unread: Bool) {
        #expect(!S.shouldRecedeSidebarThread(status: .input, isUnread: unread, isWoke: false, isActive: false, isSelected: false))
    }

    @Test func statusPrecedence() {
        #expect(status(approvals: true, runtime) == .approval)
        #expect(status(input: true, runtime) == .input)
        #expect(status(approvals: true, input: true, runtime) == .approval)
        #expect(status(runtime) == .working)
        #expect(status(ThreadRuntimeSummary(status: .starting)) == .working)
        #expect(status(nil) == .ready)
    }

    @Test func usageLimitStaysLimitedUntilRecovery() {
        let limited = ThreadRuntimeSummary(status: .failed, lastError: "Plan limit reached", lastErrorClass: .usageLimit)
        #expect(status(limited) == .limited)
        var running = limited
        running.status = .running
        #expect(status(running) == .working)
        var completed = limited
        completed.status = .completed
        #expect(status(completed) == .ready)
        #expect(S.resolveSidebarV2TopStatus(status: .limited, isUnread: false, isWoke: false) == .limited)
        #expect(!S.shouldRecedeSidebarThread(status: .limited, isUnread: false, isWoke: false, isActive: false, isSelected: false))
    }

    @Test func failedOnlyWhileTheLatestRunFailed() {
        #expect(status(ThreadRuntimeSummary(status: .failed, lastError: "boom")) == .failed)
        #expect(status(ThreadRuntimeSummary(status: .completed, lastError: "persisted")) == .ready)
        #expect(status(ThreadRuntimeSummary(status: .idle, lastError: "persisted")) == .waiting)
    }

    @Test func waitingAndDuration() {
        #expect(S.resolveSidebarV2TopStatus(status: .waiting, isUnread: true, isWoke: true) == .waiting)
        #expect(!S.shouldShowSidebarV2Duration(.waiting) && S.shouldShowSidebarV2Duration(.working))
    }

    @Test func workingStartedAt() {
        let active = ThreadRuntimeSummary(status: .running, activeRunId: "turn-1", updatedAt: "2026-03-09T10:02:00.000Z")
        #expect(S.resolveWorkingStartedAt(latestRun: latestRun(completedAt: nil), runtime: active)?.raw == "2026-03-09T10:00:00.000Z")
        #expect(S.resolveWorkingStartedAt(latestRun: latestRun(startedAt: nil, completedAt: nil), runtime: active)?.raw == "2026-03-09T10:00:00.000Z")
        #expect(S.resolveWorkingStartedAt(latestRun: latestRun(), runtime: active) == nil)
        #expect(S.resolveWorkingStartedAt(latestRun: latestRun(startedAt: "not-a-date", completedAt: nil), runtime: active)?.raw == "2026-03-09T10:00:00.000Z")
        #expect(S.resolveWorkingStartedAt(latestRun: nil, runtime: nil) == nil)
    }

    @Test(arguments: [ThreadStatus.queued, .cancelled])
    func activityStartWinsOverANewerRun(_ runStatus: ThreadStatus) {
        let run = ThreadRunSummary(runId: "newer-run", status: runStatus, requestedAt: "2026-03-09T10:00:00.000Z",
                                   completedAt: runStatus == .queued ? nil : "2026-03-09T10:05:00.000Z")
        var active = ThreadRuntimeSummary(status: .running, activeRunId: "turn-1",
                                          activityStartedAt: .value("2026-03-09T10:00:00.000Z"))
        #expect(S.resolveWorkingStartedAt(latestRun: run, runtime: active)?.raw == "2026-03-09T10:00:00.000Z")
        active.activityStartedAt = .null
        #expect(S.resolveWorkingStartedAt(latestRun: run, runtime: active) == nil)
    }

    @Test func workingDurationLabel() {
        #expect(S.formatWorkingDurationLabel(elapsedMs: 0) == "0s")
        #expect(S.formatWorkingDurationLabel(elapsedMs: 42_000) == "42s")
        #expect(S.formatWorkingDurationLabel(elapsedMs: 5 * 60_000) == "5m")
        #expect(S.formatWorkingDurationLabel(elapsedMs: 90 * 60_000) == "1h 30m")
        #expect(S.formatWorkingDurationLabel(elapsedMs: -5_000) == "0s")
        #expect(S.formatWorkingDurationLabel(elapsedMs: .nan) == "0s")
    }

    @Test func statusPill() {
        #expect(pill(approvals: true, input: true)?.label == .pendingApproval)
        #expect(pill(input: true)?.label == .awaitingInput)
        #expect(pill() == ThreadStatusPill(label: .working, pulse: true))
        let idle = ThreadRuntimeSummary(status: .idle)
        #expect(pill(runtime: idle, tasks: [PendingBackgroundTask(taskId: "bg-1", description: "Watch build", kind: .monitor, awaited: true)])
            == ThreadStatusPill(label: .waiting, pulse: false))
        #expect(pill(tasks: [PendingBackgroundTask(taskId: "bg-1", kind: .command)])?.label == .working)
        #expect(pill(runtime: idle) == nil)
        let done = ThreadRuntimeSummary(status: .completed)
        #expect(pill(plan: true, run: latestRun(), runtime: done)?.label == .planReady)
        #expect(pill(run: latestRun(), runtime: done) == nil)
        #expect(pill(mode: .default, run: latestRun(), runtime: done, visited: "2026-03-09T10:04:00.000Z")
            == ThreadStatusPill(label: .completed, pulse: false))
    }

    /// Sidebar.logic.ts:727-739 and 1121-1128 (3473, #20996): a failed run shows until the thread is visited after
    /// it ended, also when nobody ever opened it, and ranks between Awaiting Input and Working.
    @Test func unseenFailurePill() {
        var failed = latestRun()
        failed.status = .failed
        let done = ThreadRuntimeSummary(status: .failed)
        #expect(pill(mode: .default, run: failed, runtime: done) == ThreadStatusPill(label: .failed, pulse: false))
        #expect(pill(mode: .default, run: failed, runtime: done, visited: "2026-03-09T10:04:00.000Z")?.label == .failed)
        #expect(pill(mode: .default, run: failed, runtime: done, visited: "2026-03-09T10:06:00.000Z") == nil)
        #expect(pill(input: true, run: failed, runtime: done)?.label == .awaitingInput)
        #expect(S.resolveProjectStatusIndicator([ThreadStatusPill(label: .working, pulse: true), ThreadStatusPill(label: .failed, pulse: false)])?.label == .failed)
    }

    @Test func projectStatusIndicator() {
        let p = { (label: ThreadStatusPill.Label) in ThreadStatusPill(label: label, pulse: false) }
        #expect(S.resolveProjectStatusIndicator([nil, nil]) == nil)
        #expect(S.resolveProjectStatusIndicator([p(.completed), p(.pendingApproval), p(.working)])?.label == .pendingApproval)
        #expect(S.resolveProjectStatusIndicator([p(.completed), p(.planReady)])?.label == .planReady)
        #expect(S.resolveProjectStatusIndicator([p(.waiting), p(.working)])?.label == .working)
        #expect(S.resolveProjectStatusIndicator([p(.planReady), p(.waiting)])?.label == .waiting)
    }

    @Test func lastVisitedAt() {
        #expect(S.resolveThreadLastVisitedAt(server: .absent, local: "2026-07-30T10:00:00.000Z")?.raw == "2026-07-30T10:00:00.000Z")
        #expect(S.resolveThreadLastVisitedAt(server: .absent, local: nil) == nil)
        #expect(S.resolveThreadLastVisitedAt(server: .value("2026-07-30T10:00:00.000Z"), local: "2026-07-30T10:00:05.000Z")?.raw
            == "2026-07-30T10:00:00.000Z")
        #expect(S.resolveThreadLastVisitedAt(server: .value("2026-07-30T10:00:00.000Z"), local: nil)?.raw == "2026-07-30T10:00:00.000Z")
        #expect(S.resolveThreadLastVisitedAt(server: .null, local: "2026-07-30T10:00:00.000Z") == nil)
    }

    @Test(arguments: [
        (BackgroundTaskKind.command, SidebarThreadStatus.ready, SidebarTopStatus.done, false, ThreadStatusPill.Label.completed),
        (.monitor, .ready, .done, false, .completed),
        (.subagent, .waiting, .waiting, true, .waiting),
    ])
    func unseenCompletionWithBackgroundWork(
        kind: BackgroundTaskKind, expected: SidebarThreadStatus, top: SidebarTopStatus, receded: Bool, label: ThreadStatusPill.Label
    ) {
        let row = sidebarThread {
            $0.latestRunId = "run-background-completion"
            $0.status = .completed
            $0.latestRunCompletedAt = .value("2026-06-20T01:00:00.000Z")
            $0.lastVisitedAt = .value("2026-06-20T00:59:00.000Z")
            $0.pendingBackgroundTasks = [PendingBackgroundTask(taskId: "background-work", kind: kind)]
            // A 3655 server, which marks awaited work and always sends the guest count.
            $0.pendingGuestMessageCount = 0
        }
        let visited = row.shell.lastVisitedAt.value
        let status = S.resolveSidebarThreadStatus(row)
        let unread = S.hasUnseenCompletion(latestRun: row.latestRun, lastVisitedAt: visited)
        #expect(unread && status == expected)
        #expect(S.resolveSidebarV2TopStatus(status: status, isUnread: unread, isWoke: false) == top)
        #expect(S.shouldRecedeSidebarThread(status: status, isUnread: unread, isWoke: false, isActive: false, isSelected: false) == receded)
        #expect(S.resolveThreadStatusPill(row, lastVisitedAt: visited)?.label == label)
    }

    /// A server before Nightly 3655 marks nothing awaited, so a monitor keeps the thread waiting, as on 3473.
    @Test func monitorWaitsOnServersBefore3655() {
        let row = sidebarThread {
            $0.latestRunId = "run-background-completion"
            $0.status = .completed
            $0.latestRunCompletedAt = .value("2026-06-20T01:00:00.000Z")
            $0.lastVisitedAt = .value("2026-06-20T00:59:00.000Z")
            $0.pendingBackgroundTasks = [PendingBackgroundTask(taskId: "background-work", kind: .monitor)]
        }
        #expect(S.resolveSidebarThreadStatus(row) == .waiting)
        #expect(S.resolveThreadStatusPill(row, lastVisitedAt: row.shell.lastVisitedAt.value)?.label == .waiting)
    }
}

/// Ports of Sidebar.logic.test.ts project sorting and packages/client-runtime/src/state/threadSort.test.ts.
@Suite struct SidebarSortPortTests {
    @Test func pinnedOrder() {
        let pinned = { (id: String, created: String, key: String?) in
            sidebarThread(id) { $0.createdAt = T3Timestamp(created); $0.pinOrderKey = key }
        }
        let sorted = S.sortPinnedThreadsByOrderKey([
            pinned("keyless-old", "2026-03-09T08:00:00.000Z", nil),
            pinned("second", "2026-03-09T09:00:00.000Z", "t"),
            pinned("keyless-new", "2026-03-09T12:00:00.000Z", nil),
            pinned("first", "2026-03-09T07:00:00.000Z", "g"),
        ])
        #expect(sorted.map(\.id.rawValue) == ["first", "second", "keyless-new", "keyless-old"])
        let ties = S.sortPinnedThreadsByOrderKey([
            pinned("b", "2026-03-09T10:00:00.000Z", "m"), pinned("a", "2026-03-09T11:00:00.000Z", "m"),
        ])
        #expect(ties.map(\.id.rawValue) == ["a", "b"])
    }

    @Test func activeAnchorUsesUnsettle() {
        let t = thread { $0.createdAt = "2026-01-01T00:00:00.000Z"; $0.unsettledAt = "2026-08-01T00:00:00.000Z" }
        #expect(S.activeThreadAnchorTimestampMs(t) == ms("2026-08-01T00:00:00.000Z"))
    }

    @Test func activeOrder() {
        let sorted = S.sortActiveThreadsByOrderKey([
            sidebarThread("arranged-first") { $0.createdAt = "2026-03-09T09:00:00.000Z"; $0.activeOrderKey = "f" },
            sidebarThread("new") { $0.createdAt = "2026-03-09T11:00:00.000Z" },
            sidebarThread("arranged-last") {
                $0.createdAt = "2026-03-09T12:00:00.000Z"; $0.unsettledAt = "2026-03-09T13:00:00.000Z"; $0.activeOrderKey = "t"
            },
            sidebarThread("reopened") { $0.createdAt = "2026-03-01T09:00:00.000Z"; $0.unsettledAt = "2026-03-09T12:00:00.000Z" },
        ])
        #expect(sorted.map(\.id.rawValue) == ["reopened", "new", "arranged-first", "arranged-last"])
        for key in [nil, "m"] as [String?] {
            let tie = S.sortActiveThreadsByOrderKey(["thread-b", "thread-a"].map { id in
                sidebarThread(id) { $0.createdAt = "2026-03-09T10:00:00.000Z"; $0.activeOrderKey = key }
            })
            #expect(tie.map(\.id.rawValue) == ["thread-a", "thread-b"])
        }
    }

    private func settled(_ id: String, settledAt: T3Timestamp? = nil, message: T3Timestamp? = nil,
                         run: (T3Timestamp, T3Timestamp)? = nil) -> SidebarThread {
        sidebarThread(id) {
            $0.settledAt = settledAt
            $0.latestUserMessageAt = message
            $0.updatedAt = "2026-03-09T09:00:00.000Z"
            if let run {
                $0.latestRunId = "run-1"
                $0.status = .completed
                $0.latestRunRequestedAt = run.0
                $0.latestRunStartedAt = run.0
                $0.latestRunCompletedAt = .value(run.1)
            }
        }
    }

    @Test func settledTimestamp() {
        #expect(S.resolveSettledThreadTimestamp(sidebarThread {
            $0.settledAt = "2026-03-09T10:00:00.000Z"; $0.latestUserMessageAt = "2026-03-09T11:00:00.000Z"
            $0.updatedAt = "2026-03-09T12:00:00.000Z"
        })?.raw == "2026-03-09T10:00:00.000Z")
        #expect(S.resolveSettledThreadTimestamp(sidebarThread {
            $0.settledAt = "invalid"; $0.latestUserMessageAt = "2026-03-09T11:00:00.000Z"; $0.updatedAt = "2026-03-09T12:00:00.000Z"
        })?.raw == "2026-03-09T11:00:00.000Z")
        #expect(S.resolveSettledThreadTimestamp(sidebarThread { $0.updatedAt = "2026-03-09T12:00:00.000Z" })?.raw
            == "2026-03-09T12:00:00.000Z")
    }

    @Test func settledOrder() {
        let bySettle = S.sortSettledThreads([
            settled("settled-first", settledAt: "2026-03-09T10:00:00.000Z", message: "2026-03-09T09:59:00.000Z"),
            settled("settled-last", settledAt: "2026-03-09T12:00:00.000Z", message: "2026-03-09T08:00:00.000Z"),
        ])
        #expect(bySettle.map(\.id.rawValue) == ["settled-last", "settled-first"])
        let auto = S.sortSettledThreads([
            settled("auto-old", message: "2026-03-09T08:00:00.000Z"),
            settled("explicit", settledAt: "2026-03-09T10:00:00.000Z"),
            settled("auto-recent", message: "2026-03-09T11:00:00.000Z"),
        ])
        #expect(auto.map(\.id.rawValue) == ["auto-recent", "explicit", "auto-old"])
        let completion = S.sortSettledThreads([
            settled("message-only", message: "2026-03-09T10:04:00.000Z"),
            settled("completed-later", message: "2026-03-09T10:00:00.000Z",
                    run: ("2026-03-09T10:00:00.000Z", "2026-03-09T10:30:00.000Z")),
        ])
        #expect(completion.map(\.id.rawValue) == ["completed-later", "message-only"])
        let ties = S.sortSettledThreads([
            settled("b", settledAt: "2026-03-09T10:00:00.000Z"), settled("a", settledAt: "2026-03-09T10:00:00.000Z"),
        ])
        #expect(ties.map(\.id.rawValue) == ["a", "b"])
    }

    private func sortProject(_ id: String, _ title: String, created: T3Timestamp = "2026-03-09T10:00:00.000Z",
                             updated: T3Timestamp = "2026-03-09T10:00:00.000Z") -> ProjectShell {
        project(id) { $0.title = title; $0.workspaceRoot = "/w/\(id)"; $0.createdAt = created; $0.updatedAt = updated }
    }

    @Test func projectsByLatestUserMessage() {
        let threads = [
            thread("thread-1") { $0.projectId = "project-1"; $0.updatedAt = "2026-03-09T10:20:00.000Z"; $0.latestUserMessageAt = "2026-03-09T10:01:00.000Z" },
            thread("thread-2") { $0.projectId = "project-2"; $0.updatedAt = "2026-03-09T10:05:00.000Z"; $0.latestUserMessageAt = "2026-03-09T10:05:00.000Z" },
        ]
        let sorted = S.sortProjectsForSidebar([sortProject("project-1", "Older project"), sortProject("project-2", "Newer project")],
                                              threads: threads, order: .updatedAt)
        #expect(sorted.map(\.id) == ["project-2", "project-1"])
    }

    @Test func projectsFallBackToOwnStampsThenNameThenId() {
        let byStamp = S.sortProjectsForSidebar([
            sortProject("project-1", "Older project", updated: "2026-03-09T10:01:00.000Z"),
            sortProject("project-2", "Newer project", updated: "2026-03-09T10:05:00.000Z"),
        ], threads: [], order: .updatedAt)
        #expect(byStamp.map(\.id) == ["project-2", "project-1"])
        let byName = S.sortProjectsForSidebar([
            sortProject("project-2", "Beta", created: "invalid-created-at", updated: "invalid-updated-at"),
            sortProject("project-1", "Alpha", created: "invalid-created-at", updated: "invalid-updated-at"),
        ], threads: [], order: .updatedAt)
        #expect(byName.map(\.id) == ["project-1", "project-2"])
        let manual = [sortProject("project-2", "Second"), sortProject("project-1", "First")]
        #expect(S.sortProjectsForSidebar(manual, threads: [], order: .manual) == manual)
        #expect(S.getProjectSortTimestamp(sortProject("p", "P", updated: "2026-03-09T10:10:00.000Z"), threads: [], order: .updatedAt)
            == Double(ms("2026-03-09T10:10:00.000Z")))
    }

    @Test func groupsSortByActivityUnlessManual() {
        let groups = S.buildProjectGroups([sortProject("project-older", "Older project"), sortProject("project-newer", "Newer project")],
                                          mode: .separate)
        let threads = [
            thread("thread-1") { $0.projectId = "project-older"; $0.updatedAt = "2026-03-09T10:01:00.000Z" },
            thread("thread-newer") { $0.projectId = "project-newer"; $0.updatedAt = "2026-03-09T10:05:00.000Z" },
        ]
        #expect(S.sortLogicalProjectsForSidebar(groups, threads: threads, order: .manual) == groups)
        #expect(S.sortLogicalProjectsForSidebar(groups, threads: threads, order: .updatedAt).map(\.representative.id)
            == ["project-newer", "project-older"])
    }

    @Test func hiddenSubagentDoesNotReorderGroups() {
        let groups = S.buildProjectGroups([sortProject("project-older", "A older project"), sortProject("project-newer", "Z newer project")])
        let threads = [
            thread("thread-older-root") { $0.projectId = "project-older"; $0.updatedAt = "2026-03-09T10:01:00.000Z" },
            thread("thread-newer-root") { $0.projectId = "project-newer"; $0.updatedAt = "2026-03-09T10:05:00.000Z" },
            thread("thread-hidden-subagent") {
                $0.projectId = "project-older"; $0.updatedAt = "2026-03-09T10:10:00.000Z"
                $0.lineage = ThreadLineage(parentThreadId: "thread-older-root", relationshipToParent: .subagent, rootThreadId: "thread-older-root")
            },
        ]
        #expect(S.sortSidebarV2ProjectGroups(groups, threads: threads, order: .updatedAt).map(\.representative.id)
            == ["project-newer", "project-older"])
    }
}

/// Grouping, shelves and snooze, checked against projectGrouping.ts, threadSettled.ts and Sidebar.tsx.
@Suite struct SidebarDerivedStateTests {
    @Test func repositoryGroupingMergesCheckoutsAndLabelsThem() {
        var a = project("a") { $0.title = "repo"; $0.workspaceRoot = "/w/repo"; $0.repositoryIdentity = identity("github.com/x/repo") }
        let b = project("b") { $0.title = "repo"; $0.workspaceRoot = "/w/repo-copy/"; $0.repositoryIdentity = identity("github.com/x/repo") }
        let c = project("c") { $0.title = "solo"; $0.workspaceRoot = "/w/solo" }
        let groups = S.buildProjectGroups([a, b, c])
        #expect(groups.map(\.key) == ["github.com/x/repo", "/w/solo"])
        #expect(groups[0].label == "repo" && groups[0].memberProjectIds == ["a", "b"])
        a.repositoryIdentity?.displayName = "x/repo"
        var b2 = b
        b2.title = "copy"
        b2.repositoryIdentity?.displayName = "x/repo"
        #expect(S.buildProjectGroups([a, b2])[0].label == "x/repo")
        #expect(S.buildProjectGroups([a, b2], mode: .separate).count == 2)
    }

    @Test func duplicateRootsCollapseToTheFreshest() {
        let old = project("old") { $0.workspaceRoot = "/w/p"; $0.updatedAt = "2026-01-01T00:00:00.000Z" }
        let new = project("new") { $0.workspaceRoot = "/w/p/"; $0.updatedAt = "2026-02-01T00:00:00.000Z" }
        let groups = S.buildProjectGroups([old, new])
        #expect(groups.count == 1 && groups[0].representative.id == "new" && groups[0].memberProjectIds == ["old", "new"])
    }

    @Test func shelvesSplitAndOrder() {
        let now = ms("2026-03-09T12:00:00.000Z")
        let threads = [
            sidebarThread("active-old") { $0.createdAt = "2026-03-09T08:00:00.000Z" },
            sidebarThread("active-new") { $0.createdAt = "2026-03-09T09:00:00.000Z" },
            sidebarThread("pinned") { $0.pinnedAt = "2026-03-09T09:00:00.000Z" },
            sidebarThread("settled-pinned") { $0.pinnedAt = "2026-03-09T09:00:00.000Z"; $0.settledOverride = .settled },
            sidebarThread("snoozed-late") { $0.snoozedUntil = "2026-03-09T15:00:00.000Z"; $0.snoozedAt = "2026-03-09T11:00:00.000Z" },
            sidebarThread("snoozed-soon") { $0.snoozedUntil = "2026-03-09T13:00:00.000Z"; $0.snoozedAt = "2026-03-09T11:00:00.000Z" },
            sidebarThread("woke") { $0.snoozedUntil = "2026-03-09T11:30:00.000Z"; $0.snoozedAt = "2026-03-09T11:00:00.000Z" },
            sidebarThread("approval") {
                $0.snoozedUntil = "2026-03-09T15:00:00.000Z"
                $0.pendingRuntimeRequest = PendingRuntimeRequestSummary(id: "r", kind: .fileChange, createdAt: "2026-03-09T11:59:00.000Z")
            },
        ]
        let shelves = S.buildShelves(threads, capabilities: .init(threadSettlement: true, threadSnooze: true), nowMs: now)
        #expect(shelves.pinned.map(\.id) == ["pinned"])
        #expect(shelves.snoozed.map(\.id) == ["snoozed-soon", "snoozed-late"])
        #expect(shelves.settled.map(\.id) == ["settled-pinned"])
        #expect(Set(shelves.active.map(\.id)) == ["active-old", "active-new", "woke", "approval"])
        #expect(shelves.active.firstIndex { $0.id == "active-new" }! < shelves.active.firstIndex { $0.id == "active-old" }!)

        let old = S.buildShelves(threads, capabilities: .init(threadSettlement: false, threadSnooze: false), nowMs: now)
        #expect(old.snoozed.isEmpty && old.settled.isEmpty && old.pinned.map(\.id) == ["pinned", "settled-pinned"])

        let woke = threads[6]
        #expect(S.threadWokeAt(woke, nowMs: now)?.raw == "2026-03-09T11:30:00.000Z")
        #expect(S.isWoke(woke, lastVisitedAt: "2026-03-09T11:10:00.000Z", nowMs: now))
        #expect(!S.isWoke(woke, lastVisitedAt: "2026-03-09T11:40:00.000Z", nowMs: now))
        #expect(S.threadWokeAt(threads[4], nowMs: now) == nil)
    }

    /// threadSettled.ts:82-110 at T3 d2fb83a973 and 69ba80dfae.
    @Test func onlyRequestsAndFreshFailuresRaiseAHand() {
        let now = ms("2026-03-09T12:00:00.000Z")
        let failedLater = sidebarThread {
            $0.latestRunId = "r"; $0.status = .failed; $0.updatedAt = "2026-03-09T11:30:00.000Z"
            $0.snoozedAt = "2026-03-09T11:00:00.000Z"; $0.snoozedUntil = "2026-03-09T15:00:00.000Z"
        }
        #expect(S.threadRaisedHandWhileSnoozed(failedLater))
        var failedBefore = failedLater.shell
        failedBefore.updatedAt = "2026-03-09T10:30:00.000Z"
        #expect(!S.threadRaisedHandWhileSnoozed(SidebarThread(failedBefore)))
        // A metadata write bumps updatedAt after the snooze, but the run failed before it.
        var touched = failedLater.shell
        touched.latestRunCompletedAt = .value("2026-03-09T10:45:00.000Z")
        #expect(!S.threadRaisedHandWhileSnoozed(SidebarThread(touched)))
        touched.latestRunCompletedAt = .value("2026-03-09T11:20:00.000Z")
        #expect(S.threadWokeAt(SidebarThread(touched), nowMs: now)?.raw == "2026-03-09T11:20:00.000Z")
        // A run that finishes while snoozed keeps the thread hidden until its timer.
        let completed = sidebarThread {
            $0.latestRunId = "r"; $0.status = .completed; $0.latestRunCompletedAt = .value("2026-03-09T11:20:00.000Z")
            $0.snoozedAt = "2026-03-09T11:00:00.000Z"; $0.snoozedUntil = "2026-03-09T15:00:00.000Z"
        }
        #expect(!S.threadRaisedHandWhileSnoozed(completed))
        #expect(S.effectiveSnoozed(completed, nowMs: now) && S.threadWokeAt(completed, nowMs: now) == nil)
        // Any pending request wakes it, auth refresh included.
        var auth = completed.shell
        auth.pendingRuntimeRequest = PendingRuntimeRequestSummary(id: "q", kind: .authRefresh, createdAt: "2026-03-09T11:40:00.000Z")
        #expect(S.threadRaisedHandWhileSnoozed(SidebarThread(auth)) && !S.effectiveSnoozed(SidebarThread(auth), nowMs: now))
    }

    @Test func presentLatestRunFallsBackForOldServers() {
        let old = SidebarThread(thread { $0.latestRunId = "r"; $0.status = .idle; $0.updatedAt = "2026-03-09T11:00:00.000Z" })
        #expect(old.latestRun?.status == .completed && old.latestRun?.completedAt?.raw == "2026-03-09T11:00:00.000Z")
        let running = SidebarThread(thread { $0.latestRunId = "r"; $0.status = .running })
        #expect(running.latestRun?.completedAt == nil)
        #expect(SidebarThread(baseThread).runtime == nil)
    }

    @Test func rowTimeLabels() {
        let now = ms("2026-03-09T12:00:00.000Z")
        let row = sidebarThread { $0.latestUserMessageAt = "2026-03-09T11:46:00.000Z" }
        #expect(S.threadTimeLabel(row, section: .active, nowMs: now) == "14m")
        let fresh = sidebarThread { $0.updatedAt = "2026-03-09T11:59:30.000Z" }
        #expect(S.threadTimeLabel(fresh, section: .active, nowMs: now) == "now")
        let settled = sidebarThread { $0.settledAt = "2026-03-07T10:00:00.000Z" }
        #expect(S.threadTimeLabel(settled, section: .settled, nowMs: now) == "2d")
    }
}
