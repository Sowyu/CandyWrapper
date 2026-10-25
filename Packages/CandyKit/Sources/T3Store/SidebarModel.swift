import Foundation
import T3Protocol

// Sidebar derived state, ported from the official web sidebar v2 and the shared client runtime.
// Paths are relative to the pingdotgg/t3code checkout in ../CandyWrapper-research/t3code.
// Timestamps compare as epoch milliseconds; an unparseable one behaves like JS `NaN`.

// MARK: - Presented thread

/// `ThreadRuntimeSummary` as built by `shellRuntime`
/// (packages/client-runtime/src/state/models.ts:175-199).
public struct ThreadRuntimeSummary: Sendable, Equatable {
    public var status: ThreadStatus
    public var activeRunId: RunId?
    /// `.absent` on servers that predate `activityRunStartedAt`.
    public var activityStartedAt: Tristate<T3Timestamp>
    public var lastError: String?
    public var lastErrorClass: ProviderFailureClass?
    public var updatedAt: T3Timestamp?

    public init(
        status: ThreadStatus, activeRunId: RunId? = nil, activityStartedAt: Tristate<T3Timestamp> = .absent,
        lastError: String? = nil, lastErrorClass: ProviderFailureClass? = nil, updatedAt: T3Timestamp? = nil
    ) {
        self.status = status
        self.activeRunId = activeRunId
        self.activityStartedAt = activityStartedAt
        self.lastError = lastError
        self.lastErrorClass = lastErrorClass
        self.updatedAt = updatedAt
    }
}

/// `ThreadRunSummary` as built by `presentThreadShell` (models.ts:216-233).
public struct ThreadRunSummary: Sendable, Equatable {
    public var runId: RunId
    public var status: ThreadStatus
    public var requestedAt: T3Timestamp?
    public var startedAt: T3Timestamp?
    public var completedAt: T3Timestamp?

    public init(
        runId: RunId, status: ThreadStatus, requestedAt: T3Timestamp? = nil, startedAt: T3Timestamp? = nil,
        completedAt: T3Timestamp? = nil
    ) {
        self.runId = runId
        self.status = status
        self.requestedAt = requestedAt
        self.startedAt = startedAt
        self.completedAt = completedAt
    }
}

/// A thread shell plus the fields the official client derives from it in `presentThreadShell`
/// (packages/client-runtime/src/state/models.ts:209-291). Every sidebar function reads this.
public struct SidebarThread: Sendable, Equatable, Identifiable {
    public let shell: ThreadShell
    public let runtime: ThreadRuntimeSummary?
    public let latestRun: ThreadRunSummary?
    public let hasPendingApprovals: Bool
    public let hasPendingUserInput: Bool
    /// What a live subagent below this thread waits on the user for (models.ts:112-114, T3 f4df794777). Subagent rows
    /// are hidden, so the threads above them carry it. See `PendingSubagentRequests`.
    public let pendingSubagentRequest: PendingSubagentRequest?

    public var id: ThreadId { shell.id }

    public init(_ shell: ThreadShell, pendingSubagentRequest: PendingSubagentRequest? = nil) {
        self.shell = shell
        self.pendingSubagentRequest = pendingSubagentRequest
        runtime = SidebarModel.shellRuntime(shell)
        latestRun = SidebarModel.presentLatestRun(shell)
        let pending = shell.pendingRuntimeRequest
        hasPendingApprovals = pending != nil && pending?.kind != .userInput && pending?.kind != .authRefresh
        // models.ts:226-263: an async question the run keeps working past doesn't ask for input.
        let runtimeIsWorking = [.preparing, .starting, .running].contains(runtime?.status)
        hasPendingUserInput = pending?.kind == .userInput && (pending?.blocking != false || !runtimeIsWorking)
    }
}

// MARK: - Status

public enum SidebarThreadStatus: String, Sendable {
    case approval, input, working, waiting, failed, limited, ready
}

public enum SidebarTopStatus: String, Sendable {
    case approval, done, failed, limited, input, waiting, woke, working
}

public enum SidebarSection: String, Sendable, CaseIterable {
    case pinned, active, working, snoozed, settled
}

/// `ThreadStatusPill` (apps/web/src/components/Sidebar.logic.ts:626-638). Colors belong to the
/// design system; `label` carries T3's exact text.
public struct ThreadStatusPill: Sendable, Equatable {
    public enum Label: String, Sendable {
        case working = "Working"
        case connecting = "Connecting"
        case completed = "Completed"
        case failed = "Failed"
        case pendingApproval = "Pending Approval"
        case awaitingInput = "Awaiting Input"
        case waiting = "Waiting"
        case planReady = "Plan Ready"

        /// `THREAD_STATUS_PRIORITY` (Sidebar.logic.ts:640-648).
        public var priority: Double {
            switch self {
            case .pendingApproval: 5
            case .awaitingInput: 4
            case .failed: 3.5
            case .working, .connecting: 3
            case .waiting: 2.5
            case .planReady: 2
            case .completed: 1
            }
        }
    }

    public var label: Label
    public var pulse: Bool

    public init(label: Label, pulse: Bool) {
        self.label = label
        self.pulse = pulse
    }
}

public enum SidebarModel {
    static let activeRunStatuses: Set<ThreadStatus> = [.preparing, .queued, .starting, .running, .waiting]

    static func isTerminal(_ status: ThreadStatus) -> Bool {
        [.completed, .interrupted, .failed, .cancelled, .rolledBack].contains(status)
    }

    /// Port of `backgroundWorkHoldsCompletion`
    /// (packages/shared/src/orchestrationV2PendingBackgroundWork.ts:94-112). Commands and monitors
    /// hold completion only when the agent marked them `awaited`; subagents and unknown kinds
    /// always do.
    public static func backgroundWorkHoldsCompletion(_ tasks: [PendingBackgroundTask]) -> Bool {
        tasks.contains { $0.awaited || ($0.kind != .command && $0.kind != .monitor) }
    }

    /// Port of `shellRuntime` (packages/client-runtime/src/state/models.ts:175-199).
    public static func shellRuntime(_ thread: ThreadShell) -> ThreadRuntimeSummary? {
        let parkAtIdle = backgroundWorkHoldsCompletion(thread.backgroundTasks) && thread.status != .failed
        if thread.latestRunId == nil, thread.activeProviderThreadId == nil, !parkAtIdle { return nil }
        return ThreadRuntimeSummary(
            status: parkAtIdle ? .idle : (thread.activityRunStatus ?? thread.status),
            activeRunId: thread.activeRunId,
            activityStartedAt: thread.activityRunStartedAt,
            lastError: thread.lastError,
            lastErrorClass: thread.lastErrorClass,
            updatedAt: thread.updatedAt)
    }

    /// The `latestRun` part of `presentThreadShell` (models.ts:216-233). An `idle` thread reads as
    /// completed, and a server without `latestRunCompletedAt` falls back to `updatedAt` for
    /// terminal runs.
    public static func presentLatestRun(_ thread: ThreadShell) -> ThreadRunSummary? {
        guard let runId = thread.latestRunId else { return nil }
        let completedAt: T3Timestamp?
        switch thread.latestRunCompletedAt {
        case .absent:
            completedAt = thread.status == .idle || isTerminal(thread.status) ? thread.updatedAt : nil
        case .null: completedAt = nil
        case .value(let v): completedAt = v
        }
        return ThreadRunSummary(
            runId: runId, status: thread.status == .idle ? .completed : thread.status,
            requestedAt: thread.latestRunRequestedAt, startedAt: thread.latestRunStartedAt,
            completedAt: completedAt)
    }

    /// Port of `resolveSidebarThreadStatus` (apps/web/src/components/Sidebar.logic.ts:894-921).
    /// A running turn that waits on another thread reads as waiting.
    public static func resolveSidebarThreadStatus(
        hasPendingApprovals: Bool, hasPendingUserInput: Bool, runtime: ThreadRuntimeSummary?,
        blockedOnThreadWait: Bool = false
    ) -> SidebarThreadStatus {
        if hasPendingApprovals { return .approval }
        if hasPendingUserInput { return .input }
        guard let runtime else { return .ready }
        if runtime.status == .running, blockedOnThreadWait { return .waiting }
        if activeRunStatuses.contains(runtime.status) { return .working }
        if runtime.status == .idle { return .waiting }
        if runtime.status == .failed { return runtime.lastErrorClass == .usageLimit ? .limited : .failed }
        return .ready
    }

    /// A subagent's request reads as the thread's own (Sidebar.logic.ts:984-990).
    public static func resolveSidebarThreadStatus(_ thread: SidebarThread) -> SidebarThreadStatus {
        resolveSidebarThreadStatus(
            hasPendingApprovals: thread.hasPendingApprovals || thread.pendingSubagentRequest == .approval,
            hasPendingUserInput: thread.hasPendingUserInput || thread.pendingSubagentRequest == .userInput,
            runtime: thread.runtime, blockedOnThreadWait: thread.shell.blockedOnThreadWait == true)
    }

    /// Port of `resolveSidebarV2TopStatus` (Sidebar.logic.ts:1015-1039). The UI labels `working`
    /// as "Goal" when `shell.goal?.status == .active` (Sidebar.tsx:1291-1296).
    public static func resolveSidebarV2TopStatus(
        status: SidebarThreadStatus, isUnread: Bool, isWoke: Bool
    ) -> SidebarTopStatus? {
        switch status {
        case .working: return .working
        case .waiting: return .waiting
        case .approval: return .approval
        case .input: return .input
        case .failed: return .failed
        case .limited: return .limited
        case .ready: break
        }
        if isWoke { return .woke }
        return isUnread ? .done : nil
    }

    /// Port of `shouldShowSidebarV2Duration` (Sidebar.logic.ts:1041-1043).
    public static func shouldShowSidebarV2Duration(_ status: SidebarThreadStatus) -> Bool {
        status == .working
    }

    /// Port of `shouldRecedeSidebarThread` (Sidebar.logic.ts:963-978).
    public static func shouldRecedeSidebarThread(
        status: SidebarThreadStatus, isUnread: Bool, isWoke: Bool, isActive: Bool, isSelected: Bool
    ) -> Bool {
        if isActive || isSelected || status == .input { return false }
        if status == .working || status == .waiting { return true }
        if status == .ready || status == .approval { return !isUnread && !isWoke }
        return false
    }

    /// Port of `isLatestRunSettled` (apps/web/src/session-logic.ts:220-234).
    public static func isLatestRunSettled(_ latestRun: ThreadRunSummary?, _ runtime: ThreadRuntimeSummary?) -> Bool {
        guard let latestRun else { return false }
        if activeRunStatuses.contains(latestRun.status) { return false }
        return runtime?.activeRunId != latestRun.runId
    }

    /// Port of `resolveThreadStatusPill` (Sidebar.logic.ts:1061-1154), the legacy pill also used
    /// by the command palette.
    public static func resolveThreadStatusPill(
        hasPendingApprovals: Bool, hasPendingUserInput: Bool, interactionMode: InteractionMode,
        hasActionableProposedPlan: Bool, latestRun: ThreadRunSummary?, runtime: ThreadRuntimeSummary?,
        lastVisitedAt: T3Timestamp?, pendingBackgroundTasks: [PendingBackgroundTask],
        blockedOnThreadWait: Bool = false
    ) -> ThreadStatusPill? {
        if hasPendingApprovals { return ThreadStatusPill(label: .pendingApproval, pulse: false) }
        if hasPendingUserInput { return ThreadStatusPill(label: .awaitingInput, pulse: false) }
        let blocked = runtime?.status == .running && blockedOnThreadWait
        if (runtime?.status == .running && !blocked) || runtime?.status == .waiting {
            return ThreadStatusPill(label: .working, pulse: true)
        }
        if runtime?.status == .preparing || runtime?.status == .starting || runtime?.status == .queued {
            return ThreadStatusPill(label: .connecting, pulse: true)
        }
        if blocked || backgroundWorkHoldsCompletion(pendingBackgroundTasks) {
            return ThreadStatusPill(label: .waiting, pulse: false)
        }
        if hasUnseenFailure(latestRun: latestRun, lastVisitedAt: lastVisitedAt) {
            return ThreadStatusPill(label: .failed, pulse: false)
        }
        if interactionMode == .plan, isLatestRunSettled(latestRun, runtime), hasActionableProposedPlan {
            return ThreadStatusPill(label: .planReady, pulse: false)
        }
        if hasUnseenCompletion(latestRun: latestRun, lastVisitedAt: lastVisitedAt) {
            return ThreadStatusPill(label: .completed, pulse: false)
        }
        return nil
    }

    public static func resolveThreadStatusPill(_ thread: SidebarThread, lastVisitedAt: T3Timestamp?) -> ThreadStatusPill? {
        resolveThreadStatusPill(
            hasPendingApprovals: thread.hasPendingApprovals || thread.pendingSubagentRequest == .approval,
            hasPendingUserInput: thread.hasPendingUserInput || thread.pendingSubagentRequest == .userInput,
            interactionMode: thread.shell.interactionMode,
            hasActionableProposedPlan: thread.shell.hasActionableProposedPlan, latestRun: thread.latestRun,
            runtime: thread.runtime, lastVisitedAt: lastVisitedAt,
            pendingBackgroundTasks: thread.shell.backgroundTasks,
            blockedOnThreadWait: thread.shell.blockedOnThreadWait == true)
    }

    /// Port of `resolveProjectStatusIndicator` (Sidebar.logic.ts:1244-1260). First of the highest
    /// priority wins.
    public static func resolveProjectStatusIndicator(_ statuses: [ThreadStatusPill?]) -> ThreadStatusPill? {
        var best: ThreadStatusPill?
        for case let status? in statuses where best == nil || status.label.priority > best!.label.priority {
            best = status
        }
        return best
    }

    /// Port of `resolveThreadWorkingStartedAt` (models.ts:313-336), exported to the sidebar as
    /// `resolveWorkingStartedAt` (Sidebar.logic.ts:1150-1154).
    public static func resolveWorkingStartedAt(
        latestRun: ThreadRunSummary?, runtime: ThreadRuntimeSummary?
    ) -> T3Timestamp? {
        func valid(_ t: T3Timestamp?) -> T3Timestamp? { t?.isValid == true ? t : nil }
        if let runtime, !runtime.activityStartedAt.isAbsent { return valid(runtime.activityStartedAt.value) }
        if let run = latestRun, run.completedAt == nil, run.runId == runtime?.activeRunId {
            return valid(run.startedAt) ?? valid(run.requestedAt)
        }
        return nil
    }

    /// Port of `formatWorkingDurationLabel` (Sidebar.logic.ts:1156-1162): `Ns`, `Nm`, `Nh Mm`.
    public static func formatWorkingDurationLabel(elapsedMs: Double) -> String {
        let seconds = elapsedMs.isFinite ? max(0, Int((elapsedMs / 1000).rounded(.down))) : 0
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    /// Port of `firstValidTimestampMs` (Sidebar.logic.ts:1048-1057).
    public static func firstValidTimestampMs(_ candidates: T3Timestamp?...) -> Int64 {
        for case let candidate? in candidates { if let ms = candidate.epochMs { return ms } }
        return 0
    }

    // MARK: - Unread and woke

    /// Port of `resolveThreadLastVisitedAt` (Sidebar.logic.ts:762-771). The server value wins
    /// whenever the server tracks visits, including an explicit null.
    public static func resolveThreadLastVisitedAt(
        server: Tristate<T3Timestamp>, local: T3Timestamp?
    ) -> T3Timestamp? {
        switch server {
        case .absent: local
        case .null: nil
        case .value(let v): v
        }
    }

    /// Port of `hasUnseenCompletion` (Sidebar.logic.ts:773-782). A never-visited thread is read.
    public static func hasUnseenCompletion(latestRun: ThreadRunSummary?, lastVisitedAt: T3Timestamp?) -> Bool {
        guard let completed = latestRun?.completedAt?.epochMs else { return false }
        guard let lastVisitedAt else { return false }
        guard let visited = lastVisitedAt.epochMs else { return true }
        return completed > visited
    }

    /// Port of `hasUnseenFailure` (Sidebar.logic.ts:727-739): a failed latest run nobody has looked at since it
    /// ended. A thread never opened (an automation's) counts, unlike a completion.
    static func hasUnseenFailure(latestRun: ThreadRunSummary?, lastVisitedAt: T3Timestamp?) -> Bool {
        guard latestRun?.status == .failed else { return false }
        guard let lastVisitedAt else { return true }
        guard let completed = latestRun?.completedAt?.epochMs, let visited = lastVisitedAt.epochMs else { return true }
        return completed > visited
    }

    // MARK: - Snooze (packages/client-runtime/src/state/threadSettled.ts)

    /// `failureEdgeAt` (threadSettled.ts:100-110, T3 69ba80dfae): when the failure that may end a snooze happened.
    /// The outer nil means the runtime isn't failing. A failed run's completion wins over `updatedAt`, which every
    /// metadata write bumps. `error` is the legacy session status.
    private static func failureEdgeAt(_ thread: SidebarThread) -> T3Timestamp?? {
        guard let runtime = thread.runtime, runtime.status == .failed || runtime.status.rawValue == "error" else {
            return nil
        }
        if let run = thread.latestRun, run.status == .failed, let completedAt = run.completedAt { return .some(completedAt) }
        return .some(runtime.updatedAt)
    }

    /// Port of `threadRaisedHandWhileSnoozed` (threadSettled.ts:82-97). Only a request for the user or a fresh
    /// failure ends a snooze early. A finished run never does (T3 d2fb83a973), so a snoozed thread that keeps
    /// waking for background work stays hidden until its timer. Any pending request counts, auth refresh and a
    /// nonblocking question included, and so does a subagent's (T3 f4df794777).
    public static func threadRaisedHandWhileSnoozed(_ thread: SidebarThread) -> Bool {
        if thread.hasPendingApprovals || thread.hasPendingUserInput { return true }
        if thread.pendingSubagentRequest != nil { return true }
        if thread.shell.pendingRuntimeRequest != nil { return true }
        guard let failedAt = failureEdgeAt(thread) else { return false }
        guard let snoozedAt = thread.shell.snoozedAt else { return true }
        guard let failed = failedAt?.epochMs, let snoozed = snoozedAt.epochMs else { return false }
        return failed > snoozed
    }

    /// Port of `effectiveSnoozed` (threadSettled.ts:162-173). Malformed data never hides a thread.
    public static func effectiveSnoozed(_ thread: SidebarThread, nowMs: Int64) -> Bool {
        guard let wakeAt = thread.shell.snoozedUntil?.epochMs, wakeAt > nowMs else { return false }
        return !threadRaisedHandWhileSnoozed(thread)
    }

    /// Port of `threadWokeAt` (threadSettled.ts:186-211): when a snoozed thread woke, or nil.
    public static func threadWokeAt(_ thread: SidebarThread, nowMs: Int64) -> T3Timestamp? {
        guard let snoozedUntil = thread.shell.snoozedUntil, let wakeAt = snoozedUntil.epochMs else { return nil }
        if threadRaisedHandWhileSnoozed(thread) {
            // An old failure must not replace the activity time of an approval or input wake.
            if let failedAt = failureEdgeAt(thread) ?? nil {
                guard let snoozed = thread.shell.snoozedAt else { return failedAt }
                if let f = failedAt.epochMs, let s = snoozed.epochMs, f > s { return failedAt }
            }
            return thread.runtime?.updatedAt ?? thread.shell.snoozedAt
        }
        return wakeAt <= nowMs ? snoozedUntil : nil
    }

    /// The row's `isWoke` (apps/web/src/components/Sidebar.tsx:1274-1279): woke after the last
    /// visit and not settled. An unparseable visit counts as never visited.
    public static func isWoke(_ thread: SidebarThread, lastVisitedAt: T3Timestamp?, nowMs: Int64) -> Bool {
        guard let woke = threadWokeAt(thread, nowMs: nowMs)?.epochMs else { return false }
        guard thread.shell.settledOverride != .settled else { return false }
        guard let visited = lastVisitedAt?.epochMs else { return true }
        return visited < woke
    }

    // MARK: - Visibility and sections

    /// Port of `isSidebarSubagentThread` (Sidebar.logic.ts:566-568).
    public static func isSidebarSubagentThread(_ thread: ThreadShell) -> Bool {
        thread.lineage.relationshipToParent == .subagent
    }

    /// Port of `filterSidebarV2VisibleThreads` (Sidebar.logic.ts:570-583) for one environment:
    /// unarchived, not a subagent, and in scope when a scope is set.
    public static func filterSidebarV2VisibleThreads(
        _ threads: [SidebarThread], scopedProjectIds: Set<ProjectId>? = nil
    ) -> [SidebarThread] {
        threads.filter {
            $0.shell.archivedAt == nil && !isSidebarSubagentThread($0.shell)
                && (scopedProjectIds?.contains($0.shell.projectId) ?? true)
        }
    }

    /// Port of `getSidebarForkParentThreadId` (Sidebar.logic.ts:585-594).
    public static func getSidebarForkParentThreadId(_ thread: ThreadShell) -> ThreadId? {
        guard thread.lineage.relationshipToParent == .fork else { return nil }
        if let from = thread.forkedFrom, from.type == "run" { return from.threadId }
        return thread.lineage.parentThreadId
    }

    /// Port of `resolveSidebarThreadSection` (Sidebar.logic.ts:138-147). Snooze wins, then
    /// settlement, then a pin.
    public static func resolveSidebarThreadSection(snoozed: Bool, settled: Bool, pinned: Bool) -> SidebarSection {
        if snoozed { return .snoozed }
        if settled { return .settled }
        if pinned { return .pinned }
        return .active
    }

    /// Server capability flags that gate shelves (Sidebar.tsx:2799-2804).
    public struct Capabilities: Sendable {
        public var threadSettlement: Bool
        public var threadSnooze: Bool
        public init(threadSettlement: Bool, threadSnooze: Bool) {
            self.threadSettlement = threadSettlement
            self.threadSnooze = threadSnooze
        }
    }

    public struct Shelves: Sendable, Equatable {
        public var pinned: [SidebarThread] = []
        public var active: [SidebarThread] = []
        /// The Working beta shelf (`sidebarWorkingShelfEnabled`): inbox threads busy without the user.
        public var working: [SidebarThread] = []
        public var snoozed: [SidebarThread] = []
        public var settled: [SidebarThread] = []
    }

    /// `isThreadWorking` (client-runtime state/threadInbox.ts:21-34): a running run, or one stopped with
    /// background work that will wake it. Approvals, questions (its own or a subagent's), plan prompts and failures
    /// stay in the inbox.
    public static func isThreadWorking(_ thread: SidebarThread) -> Bool {
        if thread.hasPendingApprovals || thread.hasPendingUserInput { return false }
        if thread.pendingSubagentRequest != nil { return false }
        let runtimeActive = thread.runtime.map { activeRunStatuses.contains($0.status) } ?? false
        if !runtimeActive, thread.runtime?.status != .idle { return false }
        let runSettled = thread.latestRun.map { run in
            ![.preparing, .queued, .starting, .running, .waiting].contains(run.status) && thread.runtime?.activeRunId != run.runId
        } ?? false
        return !(thread.shell.interactionMode == .plan && thread.shell.hasActionableProposedPlan && runSettled)
    }

    static func sortableMs(_ t: T3Timestamp?) -> Int64 { t?.epochMs ?? 0 }

    /// Newest first by `timestamps`, then id and environment, descending/ascending as T3 (`sortNewestFirst`).
    static func sortNewestFirst(_ threads: [SidebarThread], _ timestamp: (SidebarThread) -> Int64) -> [SidebarThread] {
        threads.map { ($0, timestamp($0)) }.sorted { l, r in
            if l.1 != r.1 { return l.1 > r.1 }
            let lid = l.0.id.localId.rawValue, rid = r.0.id.localId.rawValue
            if lid != rid { return lid < rid }
            return (l.0.id.environmentId ?? "") < (r.0.id.environmentId ?? "")
        }.map(\.0)
    }

    /// `sortInboxThreadsByReturn`: newest return to the user first (created, un-settled, run requested or
    /// completed, or a return this client saw).
    public static func sortInboxThreadsByReturn(_ threads: [SidebarThread], returnedAt: (ThreadId) -> Int64?) -> [SidebarThread] {
        sortNewestFirst(threads) { t in
            max(sortableMs(t.shell.createdAt), sortableMs(t.shell.unsettledAt), sortableMs(t.latestRun?.requestedAt),
                sortableMs(t.latestRun?.completedAt), returnedAt(t.id) ?? 0)
        }
    }

    /// `sortWorkingThreadsBySend`: newest message the user sent first; servers without the authored stamp
    /// fall back to the latest run's request.
    public static func sortWorkingThreadsBySend(_ threads: [SidebarThread]) -> [SidebarThread] {
        sortNewestFirst(threads) { t in
            max(sortableMs(t.shell.createdAt), sortableMs(t.shell.latestUserAuthoredMessageAt ?? t.latestRun?.requestedAt))
        }
    }

    /// The shelf split and per-shelf order from the sidebar's memo (Sidebar.tsx:2780-2881), without
    /// drag previews. Shelves render in the order pinned, active, working, snoozed, settled. With the
    /// Working shelf on, inbox threads that are working fold into it and the inbox orders by return.
    public static func buildShelves(
        _ threads: [SidebarThread], scopedProjectIds: Set<ProjectId>? = nil, capabilities: Capabilities,
        nowMs: Int64, workingShelf: Bool = false, returnedAt: (ThreadId) -> Int64? = { _ in nil }
    ) -> Shelves {
        var shelves = Shelves()
        for thread in filterSidebarV2VisibleThreads(threads, scopedProjectIds: scopedProjectIds) {
            let section = resolveSidebarThreadSection(
                snoozed: capabilities.threadSnooze && effectiveSnoozed(thread, nowMs: nowMs),
                settled: capabilities.threadSettlement && thread.shell.settledOverride == .settled,
                pinned: thread.shell.pinnedAt != nil)
            switch section {
            case .pinned: shelves.pinned.append(thread)
            case .active, .working:
                if workingShelf, isThreadWorking(thread) { shelves.working.append(thread) } else { shelves.active.append(thread) }
            case .snoozed: shelves.snoozed.append(thread)
            case .settled: shelves.settled.append(thread)
            }
        }
        shelves.pinned = sortPinnedThreadsByOrderKey(shelves.pinned)
        shelves.active = workingShelf ? sortInboxThreadsByReturn(shelves.active, returnedAt: returnedAt) : sortActiveThreadsByOrderKey(shelves.active)
        shelves.working = sortWorkingThreadsBySend(shelves.working)
        // Soonest wake first (Sidebar.tsx:2874-2879).
        shelves.snoozed = sortSnoozedThreads(shelves.snoozed)
        shelves.settled = sortSettledThreads(shelves.settled)
        return shelves
    }

    /// Soonest wake first, ties in input order (Sidebar.tsx:2874-2879).
    public static func sortSnoozedThreads(_ threads: [SidebarThread]) -> [SidebarThread] {
        stableSorted(threads) { firstValidTimestampMs($0.shell.snoozedUntil) < firstValidTimestampMs($1.shell.snoozedUntil) }
    }

    /// The row's time label: `threadTimeLabel` (Sidebar.tsx:332-335), or `settledTimeLabel`
    /// (Sidebar.tsx:340-343) on the settled shelf.
    public static func threadTimeLabel(_ thread: SidebarThread, section: SidebarSection, nowMs: Int64) -> String {
        let timestamp: T3Timestamp?
        if section == .settled {
            timestamp = resolveSettledThreadTimestamp(thread)
        } else {
            timestamp = thread.shell.latestUserMessageAt ?? thread.shell.updatedAt
        }
        guard let timestamp else { return "" }
        return TimestampFormat.compactSidebarTimeLabel(
            TimestampFormat.formatRelativeTimeLabel(timestamp.raw, nowMs: nowMs))
    }

    // MARK: - Thread order (packages/client-runtime/src/state/threadSort.ts)

    /// JS `localeCompare` for ids and titles.
    // ponytail: approximates ICU root collation with Foundation's "en" compare, swap for ICU if titles disagree
    static func localeCompare(_ a: String, _ b: String) -> Int {
        switch a.compare(b, locale: english) {
        case .orderedAscending: -1
        case .orderedDescending: 1
        case .orderedSame: 0
        }
    }

    private static let english = Locale(identifier: "en")

    /// `items` reordered by sorting small keys instead of the items: a `SidebarThread` is a large value, and moving
    /// 1,400 of them through a sort on every shell change cost more than the comparisons (docs/research/m10-load-2026-10-12.md).
    static func sortedByKey<T, K>(_ items: [T], key: (T) -> K, by less: (K, K) -> Bool) -> [T] {
        let keys = items.map(key)
        return items.indices.sorted { less(keys[$0], keys[$1]) }.map { items[$0] }
    }

    static func stableSorted<T>(_ items: [T], by less: (T, T) -> Bool) -> [T] {
        items.enumerated().sorted { l, r in
            less(l.element, r.element) || (!less(r.element, l.element) && l.offset < r.offset)
        }.map(\.element)
    }

    /// Port of `sortPinnedThreadsByOrderKey` (threadSort.ts:306-338): keyed threads by plain
    /// string compare with an id tiebreak, then keyless threads newest created first.
    public static func sortPinnedThreadsByOrderKey(_ threads: [SidebarThread]) -> [SidebarThread] {
        guard threads.count > 1 else { return threads }
        let keyed = threads.filter { $0.shell.pinOrderKey != nil }.sorted { l, r in
            let lk = l.shell.pinOrderKey!, rk = r.shell.pinOrderKey!
            return lk != rk ? lk < rk : localeCompare(l.id.rawValue, r.id.rawValue) < 0
        }
        let keyless = threads.filter { $0.shell.pinOrderKey == nil }.sorted { l, r in
            let lt = l.shell.createdAt.epochMs ?? 0, rt = r.shell.createdAt.epochMs ?? 0
            return lt != rt ? lt > rt : localeCompare(l.id.rawValue, r.id.rawValue) < 0
        }
        return keyed + keyless
    }

    /// Port of `activeThreadAnchorTimestampMs` (threadSort.ts:123-131).
    public static func activeThreadAnchorTimestampMs(_ thread: ThreadShell) -> Int64 {
        max(thread.createdAt.epochMs ?? 0, thread.unsettledAt?.epochMs ?? 0)
    }

    /// Port of `sortActiveThreadsByOrderKey` (threadSort.ts:342-371): keyless threads first,
    /// newest anchor first; then keyed threads by key. Activity does not reorder.
    public static func sortActiveThreadsByOrderKey(_ threads: [SidebarThread]) -> [SidebarThread] {
        guard threads.count > 1 else { return threads }
        return sortedByKey(threads, key: { (order: $0.shell.activeOrderKey, anchor: activeThreadAnchorTimestampMs($0.shell), id: $0.id.rawValue) }) { l, r in
            switch (l.order, r.order) {
            case (nil, _?): return true
            case (_?, nil): return false
            case (let lk?, let rk?) where lk != rk: return lk < rk
            case (nil, nil):
                if l.anchor != r.anchor { return l.anchor > r.anchor }
            default: break
            }
            return localeCompare(l.id, r.id) < 0
        }
    }

    /// Port of `resolveSettledThreadTimestamp` (threadSort.ts:29-51): `settledAt`, else the latest
    /// of the user message and run stamps, else `updatedAt`.
    public static func resolveSettledThreadTimestamp(_ thread: SidebarThread) -> T3Timestamp? {
        if let settledAt = thread.shell.settledAt, settledAt.isValid { return settledAt }
        var latest: T3Timestamp?
        for case let candidate? in [
            thread.shell.latestUserMessageAt, thread.latestRun?.requestedAt, thread.latestRun?.startedAt,
            thread.latestRun?.completedAt,
        ] {
            if let ms = candidate.epochMs, ms > (latest?.epochMs ?? Int64.min) { latest = candidate }
        }
        if let latest { return latest }
        return thread.shell.updatedAt.isValid ? thread.shell.updatedAt : nil
    }

    /// Port of `sortSettledThreads` (threadSort.ts:56-69): newest end of work first, id tiebreak.
    public static func sortSettledThreads(_ threads: [SidebarThread]) -> [SidebarThread] {
        sortedByKey(threads, key: { (ms: resolveSettledThreadTimestamp($0)?.epochMs ?? 0, id: $0.id.rawValue) }) { l, r in
            l.ms != r.ms ? l.ms > r.ms : localeCompare(l.id, r.id) < 0
        }
    }

    public enum SortOrder: String, Sendable {
        case updatedAt = "updated_at"
        case createdAt = "created_at"
        case manual
    }

    /// Port of `getThreadSortTimestamp` (threadSort.ts:107-117) for shells, which carry no messages.
    public static func getThreadSortTimestamp(_ thread: ThreadShell, _ order: SortOrder) -> Double {
        if order == .createdAt {
            return (thread.createdAt.epochMs ?? thread.updatedAt.epochMs).map(Double.init) ?? -.infinity
        }
        if let ms = thread.latestUserMessageAt?.epochMs { return Double(ms) }
        if let ms = thread.updatedAt.epochMs ?? thread.createdAt.epochMs { return Double(ms) }
        return -.infinity
    }

    // MARK: - Projects

    /// Port of `getProjectSortTimestamp` (Sidebar.logic.ts:1288-1304).
    public static func getProjectSortTimestamp(
        _ project: ProjectShell, threads: [ThreadShell], order: SortOrder
    ) -> Double {
        if !threads.isEmpty {
            return threads.reduce(-Double.infinity) { max($0, getThreadSortTimestamp($1, order)) }
        }
        // T3's `updatedAt ?? createdAt` falls through only on a missing value, and the shell
        // always has `updatedAt`, so an invalid one sorts last.
        let ms = order == .createdAt ? project.createdAt.epochMs : project.updatedAt.epochMs
        return ms.map(Double.init) ?? -.infinity
    }

    /// Port of `sortProjectsByActivity` (Sidebar.logic.ts:1306-1329).
    static func sortProjectsByActivity<P>(
        _ projects: [P], order: SortOrder, timestamp: (P) -> Double, ties: (P, P) -> Bool
    ) -> [P] {
        if order == .manual { return projects }
        return projects.map { ($0, timestamp($0)) }.sorted { l, r in
            l.1 != r.1 ? l.1 > r.1 : ties(l.0, r.0)
        }.map(\.0)
    }

    /// Port of `sortProjectsForSidebar` (Sidebar.logic.ts:1331-1352).
    public static func sortProjectsForSidebar(
        _ projects: [ProjectShell], threads: [ThreadShell], order: SortOrder
    ) -> [ProjectShell] {
        let byProject = Dictionary(grouping: threads, by: \.projectId)
        return sortProjectsByActivity(
            projects, order: order,
            timestamp: { getProjectSortTimestamp($0, threads: byProject[$0.id] ?? [], order: order) },
            ties: { l, r in
                let byTitle = localeCompare(l.title, r.title)
                return byTitle != 0 ? byTitle < 0 : localeCompare(l.id.rawValue, r.id.rawValue) < 0
            })
    }

    /// `SidebarProjectGroupingMode` (packages/contracts/src/settings.ts:67-73).
    public enum ProjectGroupingMode: String, Sendable, Hashable {
        case repository
        /// The same repository and the same folder inside it.
        case repositoryPath = "repository_path"
        case separate
    }

    /// `ProjectGroupingSettings`: the `sidebarProjectGroupingMode` client setting and its per-project
    /// overrides, keyed by physical project key (`deriveProjectGroupingOverrideKey`).
    public struct ProjectGrouping: Hashable, Sendable {
        public var mode: ProjectGroupingMode
        public var overrides: [String: ProjectGroupingMode]
        public init(mode: ProjectGroupingMode = .repository, overrides: [String: ProjectGroupingMode] = [:]) {
            self.mode = mode; self.overrides = overrides
        }

        /// `resolveProjectGroupingMode`.
        public func mode(for project: ProjectShell) -> ProjectGroupingMode { overrides[physicalProjectKey(project)] ?? mode }

        /// The client settings' grouping, which every caller of `buildProjectGroups` uses unless it passes one.
        public static var current: ProjectGrouping {
            get { currentLock.withLock { $0 } }
            set { currentLock.withLock { $0 = newValue } }
        }
        static let currentLock = PortableLock(initialState: ProjectGrouping())
    }

    /// A logical project: one or more physical projects shown under one label.
    public struct ProjectGroup: Sendable, Equatable, Identifiable {
        public var key: String
        public var label: String
        public var representative: ProjectShell
        /// Deduplicated physical projects, one per workspace root.
        public var members: [ProjectShell]
        /// Every project id that maps to this group, duplicates included. Threads join on these.
        public var memberProjectIds: [ProjectId]
        public var id: String { key }
    }

    /// Port of `normalizeProjectPathForComparison` (packages/shared/src/path.ts:49-55) for POSIX
    /// paths: trim, then drop trailing slashes.
    public static func normalizeProjectPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != "/" else { return trimmed }
        var result = Substring(trimmed)
        while result.hasSuffix("/") { result = result.dropLast() }
        return result.isEmpty ? trimmed : String(result)
    }

    /// Port of `derivePhysicalProjectKey` (projectGrouping.ts:69-77): `<environmentId>:<normalized root>`.
    /// The environment comes from the scoped project id (`EnvironmentScope`); an unscoped id has none.
    public static func physicalProjectKey(_ project: ProjectShell) -> String {
        let root = normalizeProjectPath(project.workspaceRoot)
        return project.id.environmentId.map { EnvironmentScope.key($0, root) } ?? root
    }

    /// Port of `deriveLogicalProjectKey` (packages/client-runtime/src/state/projectGrouping.ts:126-145).
    /// The same repository in two environments gets one key, so it forms one sidebar group.
    public static func deriveLogicalProjectKey(_ project: ProjectShell, mode: ProjectGroupingMode) -> String {
        let physical = physicalProjectKey(project)
        if mode == .separate { return physical }
        guard let canonical = project.repositoryIdentity?.groupingKey else { return physical }
        if mode == .repository { return canonical }
        // `deriveRepositoryScopedKey` for `repository_path`: the folder's path inside the repository.
        guard let root = project.repositoryIdentity?.rootPath?.trimmingCharacters(in: .whitespacesAndNewlines), !root.isEmpty else { return canonical }
        let path = normalizeProjectPath(project.workspaceRoot), base = normalizeProjectPath(root)
        guard !path.isEmpty, !base.isEmpty else { return canonical }
        if path == base { return canonical }
        let separator = base.contains("\\") ? "\\" : "/"
        guard path.hasPrefix(base + separator) else { return canonical }
        let relative = String(path.dropFirst(base.count + 1)).replacingOccurrences(of: "\\", with: "/")
        return relative.isEmpty ? canonical : "\(canonical)::\(relative)"
    }

    /// Port of `deriveProjectGroupLabel` (projectGrouping.ts:159-190).
    public static func deriveProjectGroupLabel(representative: ProjectShell, members: [ProjectShell]) -> String {
        func unique(_ values: [String?]) -> [String] {
            var seen = Set<String>(), out: [String] = []
            for case let value? in values {
                let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty, seen.insert(t).inserted { out.append(t) }
            }
            return out
        }
        let titles = unique(members.map(\.title))
        let displayNames = unique(members.map { $0.repositoryIdentity?.groupingDisplayName })
        let repoNames = unique(members.map { $0.repositoryIdentity?.name })
        if titles.count == 1, !displayNames.contains(titles[0]), !repoNames.contains(titles[0]) { return titles[0] }
        if displayNames.count == 1 { return displayNames[0] }
        if repoNames.count == 1 { return repoNames[0] }
        return representative.title
    }

    /// Port of `buildProjectGroups` (projectGrouping.ts:255-326). Projects with the same environment and
    /// workspace root collapse to the freshest; groups keep first-seen order. The representative is the
    /// member in `preferredEnvironmentId` (the primary environment) when there is one, else the first.
    /// Remembers the last result: every sidebar build, scope lookup and composer update asks with the
    /// same projects until one changes.
    // ponytail: one entry; key by caller if two callers start alternating different project lists
    public static func buildProjectGroups(_ projects: [ProjectShell], grouping: ProjectGrouping = .current,
                                          preferredEnvironmentId: String? = nil) -> [ProjectGroup] {
        let key = GroupsKey(projects: projects, grouping: grouping, preferred: preferredEnvironmentId)
        if let hit = groupsCache.withLock({ $0?.key == key ? $0?.groups : nil }) { return hit }
        let groups = computeProjectGroups(projects, grouping: grouping, preferredEnvironmentId: preferredEnvironmentId)
        groupsCache.withLock { $0 = (key, groups) }
        return groups
    }

    /// One grouping mode for every project, no overrides.
    public static func buildProjectGroups(_ projects: [ProjectShell], mode: ProjectGroupingMode,
                                          preferredEnvironmentId: String? = nil) -> [ProjectGroup] {
        buildProjectGroups(projects, grouping: ProjectGrouping(mode: mode), preferredEnvironmentId: preferredEnvironmentId)
    }

    struct GroupsKey: Equatable, Sendable {
        var projects: [ProjectShell]
        var grouping: ProjectGrouping
        var preferred: String?
    }
    static let groupsCache = PortableLock<(key: GroupsKey, groups: [ProjectGroup])?>(initialState: nil)

    static func computeProjectGroups(_ projects: [ProjectShell], grouping: ProjectGrouping,
                                             preferredEnvironmentId: String?) -> [ProjectGroup] {
        func freshness(_ p: ProjectShell) -> Int64 { p.updatedAt.epochMs ?? p.createdAt.epochMs ?? 0 }
        func replaces(_ existing: ProjectShell, _ candidate: ProjectShell) -> Bool {
            let delta = freshness(candidate) - freshness(existing)
            return delta > 0 || (delta == 0 && candidate.id.rawValue > existing.id.rawValue)
        }
        var physicalOrder: [String] = []
        var byPhysical: [String: [ProjectShell]] = [:]
        for project in projects {
            let key = physicalProjectKey(project)
            if byPhysical[key] == nil { physicalOrder.append(key) }
            byPhysical[key, default: []].append(project)
        }
        var groupOrder: [String] = []
        var members: [String: [ProjectShell]] = [:]
        var logicalByPhysical: [String: String] = [:]
        for physical in physicalOrder {
            let candidates = byPhysical[physical]!
            let winner = candidates.dropFirst().reduce(candidates[0]) { replaces($0, $1) ? $1 : $0 }
            var identitySource = winner
            if winner.repositoryIdentity == nil {
                identitySource = candidates.filter { $0.repositoryIdentity != nil }
                    .reduce(nil as ProjectShell?) { best, p in best.map { replaces($0, p) ? p : $0 } ?? p } ?? winner
            }
            let key = deriveLogicalProjectKey(identitySource, mode: grouping.mode(for: winner))
            logicalByPhysical[physical] = key
            if members[key] == nil { groupOrder.append(key) }
            members[key, default: []].append(winner)
        }
        var ids: [String: [ProjectId]] = [:]
        var seen = Set<ProjectId>()
        for project in projects where seen.insert(project.id).inserted {
            ids[logicalByPhysical[physicalProjectKey(project)]!, default: []].append(project.id)
        }
        return groupOrder.map { key in
            let group = members[key]!
            let representative = preferredEnvironmentId.flatMap { env in group.first { $0.id.environmentId == env } } ?? group[0]
            return ProjectGroup(
                key: key,
                label: group.count > 1
                    ? deriveProjectGroupLabel(representative: representative, members: group) : representative.title,
                representative: representative, members: group, memberProjectIds: ids[key] ?? [])
        }
    }

    /// Port of `sortLogicalProjectsForSidebar` (Sidebar.logic.ts:1354-1390). A group sorts by its
    /// newest unarchived thread, else by its representative's own stamps; ties by title, then key.
    public static func sortLogicalProjectsForSidebar(
        _ groups: [ProjectGroup], threads: [ThreadShell], order: SortOrder
    ) -> [ProjectGroup] {
        sortLogicalProjects(groups, threads: threads, order: order) { $0.archivedAt == nil }
    }

    private static func sortLogicalProjects(
        _ groups: [ProjectGroup], threads: [ThreadShell], order: SortOrder, counts: (ThreadShell) -> Bool
    ) -> [ProjectGroup] {
        var groupByProject: [ProjectId: String] = [:]
        for group in groups { for id in group.memberProjectIds { groupByProject[id] = group.key } }
        // The newest thread per group, without copying the large shells into per-group arrays (the palette
        // runs this on every key; with 1,000 threads the copies took most of a 0.26 s stall).
        var newestByGroup: [String: Double] = [:]
        for thread in threads where counts(thread) {
            if let key = groupByProject[thread.projectId] {
                newestByGroup[key] = max(newestByGroup[key] ?? -.infinity, getThreadSortTimestamp(thread, order))
            }
        }
        return sortProjectsByActivity(
            groups, order: order,
            timestamp: { newestByGroup[$0.key] ?? getProjectSortTimestamp($0.representative, threads: [], order: order) },
            ties: { l, r in
                let byTitle = localeCompare(l.representative.title, r.representative.title)
                return byTitle != 0 ? byTitle < 0 : localeCompare(l.key, r.key) < 0
            })
    }

    /// Port of `sortSidebarV2ProjectGroups` (Sidebar.logic.ts:1392-1405): hidden subagent and
    /// archived threads don't move a project.
    public static func sortSidebarV2ProjectGroups(
        _ groups: [ProjectGroup], threads: [ThreadShell], order: SortOrder
    ) -> [ProjectGroup] {
        sortLogicalProjects(groups, threads: threads, order: order) { $0.archivedAt == nil && !isSidebarSubagentThread($0) }
    }

    /// The manual project order (`projectOrder`, uiStateStore.ts:23-60): T3 keeps it on the client as physical
    /// project keys (`getProjectOrderKey`). `orderItemsByPreferredIds` puts the stored keys first and the rest after
    /// in snapshot order, so a new project lands at the end; `buildProjectGroups` keeps first-seen order, so a group
    /// sits where its first member does (useSidebarProjectGroups.ts:17-35).
    public static func orderProjectGroups(_ groups: [ProjectGroup], projects: [ProjectShell], preferred: [String]) -> [ProjectGroup] {
        guard !preferred.isEmpty else { return groups }
        let rank = projectRanks(projects, preferred: preferred)
        let groupRank = groups.map { g in g.memberProjectIds.compactMap { rank[$0] }.min() ?? Int.max }
        return groups.indices.sorted { groupRank[$0] == groupRank[$1] ? $0 < $1 : groupRank[$0] < groupRank[$1] }.map { groups[$0] }
    }

    /// Each project's place in the manual order: stored keys first, the rest after them in snapshot order.
    static func projectRanks(_ projects: [ProjectShell], preferred: [String]) -> [ProjectId: Int] {
        var stored: [String: Int] = [:]
        for (i, key) in preferred.enumerated() where stored[key] == nil { stored[key] = i }
        var rank: [ProjectId: Int] = [:]
        for (i, p) in projects.enumerated() { rank[p.id] = stored[physicalProjectKey(p)] ?? preferred.count + i }
        return rank
    }

    /// Groups in the `sidebarProjectSortOrder` setting's order: Manual reads the stored order, the others sort by activity.
    public static func sortProjectGroups(_ groups: [ProjectGroup], projects: [ProjectShell], threads: [ThreadShell],
                                         order: SortOrder, preferred: [String]) -> [ProjectGroup] {
        order == .manual ? orderProjectGroups(groups, projects: projects, preferred: preferred)
            : sortSidebarV2ProjectGroups(groups, threads: threads, order: order)
    }

    /// A project group dragged before `target`, or to the end for nil (`reorderProjects`, uiStateStore.ts:376-418, with the
    /// drop line's before-this-group slot instead of dnd-kit's swap). `groups` is the order on screen; the result is the
    /// new stored order, every project's key, so later projects keep landing after it.
    public static func movingProjectGroup(_ key: String, before target: String?, groups: [ProjectGroup],
                                          projects: [ProjectShell], preferred: [String]) -> [String] {
        var order = groups
        guard key != target, let from = order.firstIndex(where: { $0.key == key }) else { return currentOrder(groups, projects, preferred) }
        let moved = order.remove(at: from)
        let at = target.flatMap { t in order.firstIndex { $0.key == t } } ?? order.count
        order.insert(moved, at: at)
        return currentOrder(order, projects, preferred)
    }

    private static func currentOrder(_ groups: [ProjectGroup], _ projects: [ProjectShell], _ preferred: [String]) -> [String] {
        let rank = projectRanks(projects, preferred: preferred)
        let byId = Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<String>(), keys: [String] = []
        for group in groups {
            let members = group.memberProjectIds.sorted { (rank[$0] ?? .max) < (rank[$1] ?? .max) }
            for id in members {
                guard let p = byId[id] else { continue }
                let k = physicalProjectKey(p)
                if seen.insert(k).inserted { keys.append(k) }
            }
        }
        // Projects in no group on screen (another grouping, a hidden environment) keep their stored place at the end.
        for k in preferred where seen.insert(k).inserted { keys.append(k) }
        return keys
    }
}

/// `createInboxReturnTracker` (client-runtime state/threadInbox.ts:110-148): when this client saw each
/// thread leave the Working section. The first observation only takes a baseline, so turning the beta
/// on never reshuffles the inbox.
public final class SidebarInboxReturnTracker: @unchecked Sendable {
    private var lastWorking: Set<ThreadId>?
    private var returns: [ThreadId: Int64] = [:]

    public init() {}

    /// Every thread shell on each rebuild, or nil to reset while the beta is off.
    public func observe(_ threads: [SidebarThread]?, nowMs: Int64) {
        guard let threads else { lastWorking = nil; returns = [:]; return }
        var working = Set<ThreadId>(), present = Set<ThreadId>()
        for t in threads {
            present.insert(t.id)
            if SidebarModel.isThreadWorking(t) { working.insert(t.id) }
        }
        returns = returns.filter { present.contains($0.key) }
        for id in lastWorking ?? [] where present.contains(id) && !working.contains(id) { returns[id] = nowMs }
        lastWorking = working
    }

    public func returnedAt(_ id: ThreadId) -> Int64? { returns[id] }
}
