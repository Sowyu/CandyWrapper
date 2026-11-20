import Foundation
import T3Protocol

// Thread notifications, ported from apps/web/src/threadNotifications.ts and
// apps/web/src/components/ThreadNotificationCoordinator.tsx. The views, the sound, the system
// notification and the dock badge live in the app; this file decides when to notify.

/// The client setting `notificationMode` (threadNotifications.ts:6-20).
public enum ThreadNotificationMode: String, Sendable, CaseIterable {
    case off, notifications, sound
    case notificationsAndSound = "notifications-and-sound"

    /// `NOTIFICATION_MODE_LABELS`.
    public var label: String {
        switch self {
        case .off: "Off"
        case .notifications: "Notifications only"
        case .sound: "Sound only"
        case .notificationsAndSound: "Notifications with sound"
        }
    }

    /// `hasNotificationSound`.
    public var hasSound: Bool { self == .sound || self == .notificationsAndSound }
    /// `hasDesktopNotifications`.
    public var hasDesktopNotifications: Bool { self == .notifications || self == .notificationsAndSound }
}

/// One thread that should alert the user, with T3's wording (ThreadNotificationCoordinator.tsx:150-166).
public struct ThreadNotificationEvent: Sendable, Equatable {
    public enum Kind: String, Sendable { case completion, input }
    /// The toast's leading icon and tone (ThreadNotificationCoordinator.tsx:179-193).
    public enum Icon: String, Sendable { case circleCheck, shieldQuestion, circleAlert, messageCircleQuestion }
    public enum Tone: String, Sendable { case success, error, warning }

    public let environmentId: String
    /// The thread's id on its environment (not scoped).
    public let threadId: ThreadId
    public let threadTitle: String
    public let kind: Kind
    public let status: SidebarThreadStatus

    /// "Thread completed", "Approval needed", "Usage limit reached", "Thread failed", "Guest request" or "Input needed".
    public var title: String {
        if kind == .completion { return "Thread completed" }
        switch status {
        case .approval: return "Approval needed"
        case .limited: return "Usage limit reached"
        case .failed: return "Thread failed"
        case .request: return "Guest request"
        default: return "Input needed"
        }
    }

    public var tone: Tone { kind == .completion ? .success : status == .failed ? .error : .warning }

    public var icon: Icon {
        if kind == .completion { return .circleCheck }
        switch status {
        case .approval: return .shieldQuestion
        case .failed: return .circleAlert
        default: return .messageCircleQuestion
        }
    }

    /// The system notification's `tag`: one notification per thread, a newer one replaces it.
    public var tag: String { "\(environmentId):\(threadId.rawValue)" }
}

/// `EnvironmentNotifications`' diff over one environment's live shell (4928 ThreadNotificationCoordinator.tsx:235-360)
/// and `createThreadNotificationGate` (4928 ThreadNotificationCoordinator.logic.ts:39-133). A thread seen for the first
/// time never notifies, so connecting to a server with finished threads is quiet. Attention and completion notify at
/// once (#29146); only a completion that answers a background progress wake waits `releasedCompletionGraceMs`, in
/// `flush`, since a final wake can start right after it. Snoozed threads send no completion (#27458). While the shell
/// is not live the environment is paused, not forgotten, so what changed meanwhile notifies on reconnect (#24493).
public struct ThreadNotificationTracker: Sendable {
    /// `RELEASED_COMPLETION_GRACE_MS`.
    public static let releasedCompletionGraceMs: Int64 = 5_000

    struct State: Sendable {
        var raw: ThreadShell
        var subagentRequest: PendingSubagentRequest?
        var attention: String?
        var requestId: String?
        var settled: Bool
        var completedAt: Int64?
        var backgroundWake: Bool
        var event: ThreadNotificationEvent
    }

    struct Release: Sendable {
        var at: Int64
        /// Nil while paused: no wake until the next observation restarts it.
        var dueMs: Int64?
        var event: ThreadNotificationEvent
    }

    struct Gate: Sendable {
        var releases: [ThreadId: Release] = [:]
        /// The newest completion already notified, or deliberately skipped.
        var handled: [ThreadId: Int64] = [:]
        /// Attention keys with a request id seen since the thread last stopped needing attention.
        var attended: [ThreadId: Set<String>] = [:]
        /// The shell went stale: the next scan observes every thread again.
        var reconnecting = false

        mutating func skip(_ id: ThreadId, _ at: Int64?) {
            if let at, at > (handled[id] ?? .min) { handled[id] = at }
        }

        mutating func attend(_ id: ThreadId, _ prior: State?, _ next: State) -> Bool {
            guard let attention = next.attention else { attended[id] = nil; return false }
            guard next.requestId != nil else { return attention != prior?.attention }
            if attended[id]?.contains(attention) == true { return false }
            attended[id, default: []].insert(attention)
            return true
        }
    }

    private var previous: [String: [ThreadId: State]] = [:]
    private var gates: [String: Gate] = [:]

    public init() {}

    /// The environment left or notifications turned off: forget it, like `gate.clear()`.
    public mutating func reset(environmentId: String) {
        previous[environmentId] = nil
        gates[environmentId] = nil
    }

    public mutating func resetAll() {
        previous = [:]
        gates = [:]
    }

    /// The snapshot went stale (`entry.reconnecting = true; entry.gate.pause()`): grace timers stop and the next
    /// live scan compares every thread with what was last seen.
    public mutating func pause(environmentId: String) {
        guard var gate = gates[environmentId] else { return }
        for id in gate.releases.keys { gate.releases[id]?.dueMs = nil }
        gate.reconnecting = true
        gates[environmentId] = gate
    }

    /// When the next held completion is due, or nil while none is held.
    public var nextDueMs: Int64? { gates.values.flatMap { $0.releases.values.compactMap(\.dueMs) }.min() }

    /// The held completions due by `nowMs`, which count as notified.
    public mutating func flush(nowMs: Int64) -> [ThreadNotificationEvent] {
        var events: [ThreadNotificationEvent] = []
        for env in gates.keys.sorted() {
            guard var gate = gates[env] else { continue }
            for (id, r) in gate.releases.sorted(by: { ($0.value.dueMs ?? .max) < ($1.value.dueMs ?? .max) }) {
                guard let due = r.dueMs, due <= nowMs else { continue }
                gate.releases[id] = nil
                gate.handled[id] = r.at
                events.append(r.event)
            }
            gates[env] = gate
        }
        return events
    }

    /// `isSnoozedForNotification` (logic.ts:24-37): a completion that landed during the snooze stays quiet even when
    /// its update arrives after the wake.
    static func snoozedForNotification(_ thread: SidebarThread, completedAt: Int64?, nowMs: Int64) -> Bool {
        if SidebarModel.effectiveSnoozed(thread, nowMs: nowMs) { return true }
        guard let completedAt else { return false }
        if let snoozedAt = thread.shell.snoozedAt?.epochMs, completedAt < snoozedAt { return false }
        return SidebarModel.effectiveSnoozed(thread, nowMs: completedAt)
    }

    /// `monitorHoldsWakeCompletion` (shared orchestrationV2PendingBackgroundWork.ts:120-129).
    static func monitorHoldsWakeCompletion(_ raw: ThreadShell) -> Bool {
        raw.latestRunBackgroundWake == true && raw.backgroundTasks.contains { $0.kind == .monitor && !$0.taskId.hasPrefix("pull-request-watch:") }
    }

    /// Diffs the environment's live threads against the last scan and returns the notifications due now. Wake
    /// completions wait in `flush`.
    public mutating func scan(environmentId: String, threads: [ThreadShell], nowMs: Int64) -> [ThreadNotificationEvent] {
        let before = previous[environmentId] ?? [:]
        var gate = gates[environmentId] ?? Gate()
        let reconnecting = gate.reconnecting
        var next: [ThreadId: State] = [:]
        var changed: [(prior: State?, state: State, thread: SidebarThread)] = []
        // Subagents are skipped below, so their requests notify through the thread above them (T3 f4df794777).
        let subagentRequests = PendingSubagentRequests.byThread(threads)
        for raw in threads {
            // Side chats too, as `isShownUnderParent` (4928 ThreadNotificationCoordinator.tsx:250).
            if !raw.lineage.isListed { continue }
            let prior = before[raw.id]
            let subagentRequest = subagentRequests[raw.id]
            // An unchanged thread can't produce a new notification, unless the shell just came back.
            if !reconnecting, let prior, prior.raw == raw, prior.subagentRequest == subagentRequest {
                next[raw.id] = prior
                continue
            }
            let thread = SidebarThread(raw, pendingSubagentRequest: subagentRequest)
            var status = SidebarModel.resolveSidebarThreadStatus(thread)
            if status == .ready, thread.latestRun?.status == .failed { status = .failed }
            let needsAttention = [.input, .request, .approval, .failed, .limited].contains(status)
            // `resolveBackgroundThreadRequest` (backgroundThreadAnnouncement.ts:27-41): the thread's own request id.
            let requestId = needsAttention && (thread.hasPendingApprovals || thread.hasPendingUserInput) ? raw.pendingRuntimeRequest?.id.rawValue : nil
            // Queued messages become the latest run while a request stays pending, so a request with an id is
            // keyed by that id alone and announces once.
            let attention: String? = !needsAttention ? nil
                : requestId.map { "\(status.rawValue):\($0)" } ?? "\(thread.latestRun?.runId.rawValue ?? ""):\(status.rawValue)"
            // Commands left running (a dev server) read as ready; subagents and awaited work wait.
            let settled = status == .ready && thread.latestRun?.status == .completed && !Self.monitorHoldsWakeCompletion(raw)
            let state = State(raw: raw, subagentRequest: subagentRequest, attention: attention, requestId: requestId, settled: settled,
                              completedAt: settled ? thread.latestRun?.completedAt?.epochMs : nil,
                              backgroundWake: raw.latestRunBackgroundWake == true,
                              event: ThreadNotificationEvent(environmentId: environmentId, threadId: raw.id, threadTitle: raw.title,
                                                             kind: .input, status: status))
            next[raw.id] = state
            changed.append((prior, state, thread))
        }
        gate.reconnecting = false
        previous[environmentId] = next
        // `retain`: forget threads that left the snapshot.
        gate.releases = gate.releases.filter { next[$0.key] != nil }
        gate.handled = gate.handled.filter { next[$0.key] != nil }
        gate.attended = gate.attended.filter { next[$0.key] != nil }
        var events: [ThreadNotificationEvent] = []
        for (prior, state, thread) in changed {
            let id = state.raw.id
            let archived = state.raw.archivedAt != nil
            // A run the user stopped or a compaction T3 Code started doesn't announce itself
            // (ThreadNotificationCoordinator.tsx:308-312). Failures still do, through `attention`.
            let quiet = state.raw.latestRunStopRequested == true || state.raw.latestRunSilent == true
            let snoozed = Self.snoozedForNotification(thread, completedAt: state.completedAt, nowMs: nowMs)
            let silenced = archived || quiet || snoozed
            let completion = ThreadNotificationEvent(environmentId: environmentId, threadId: id, threadTitle: state.raw.title,
                                                     kind: .completion, status: state.event.status)
            // The grace survives updates that keep the wake's completion; anything else cancels it.
            if let pending = gate.releases[id], pending.at == state.completedAt, !silenced {
                if pending.dueMs == nil { gate.releases[id]?.dueMs = nowMs + Self.releasedCompletionGraceMs }
                continue
            }
            gate.releases[id] = nil
            // The first sighting, archived or snoozed threads, and stopped or silent runs never notify completion.
            if prior == nil || silenced { gate.skip(id, state.completedAt) }
            let fresh = gate.attend(id, prior, state)
            guard prior != nil, !archived else { continue }
            if fresh { events.append(state.event); continue }
            guard state.settled, let at = state.completedAt, at > (gate.handled[id] ?? .min) else { continue }
            if state.backgroundWake {
                gate.releases[id] = Release(at: at, dueMs: nowMs + Self.releasedCompletionGraceMs, event: completion)
                continue
            }
            gate.handled[id] = at
            events.append(completion)
        }
        gates[environmentId] = gate
        return events
    }
}

/// The dock badge: how many threads have a system notification waiting (ThreadNotificationCoordinator.tsx:33-68,
/// apps/desktop/src/ipc/methods/notificationBadge.ts). Each thread counts once; focusing the window clears all.
public struct NotificationBadgeCount: Sendable, Equatable {
    /// tag to environment id.
    public private(set) var pending: [String: String] = [:]

    public init() {}

    public var count: Int { pending.count }

    /// A system notification went out. Returns the badge to show: 0 while the window has focus
    /// (`applyNotificationBadge`: a focused window clears instead).
    public mutating func add(tag: String, environmentId: String, windowFocused: Bool) -> Int {
        if windowFocused {
            pending = [:]
            return 0
        }
        pending[tag] = environmentId
        return pending.count
    }

    /// Focus, quit, or a mode change: returns the tags whose notifications to withdraw.
    public mutating func clear() -> [String] {
        defer { pending = [:] }
        return Array(pending.keys)
    }

    /// Environments that left: drops their notifications (returns their tags).
    public mutating func keep(environments: Set<String>) -> [String] {
        let gone = pending.filter { !environments.contains($0.value) }.map(\.key)
        for tag in gone { pending[tag] = nil }
        return gone
    }
}

/// Where one notification goes (ThreadNotificationCoordinator.tsx:167-232). The sound plays in every
/// case its mode allows. A focused window shows a toast unless the thread is the open one; a window
/// without focus gets the system notification instead.
public struct ThreadNotificationRoute: Sendable, Equatable {
    public var sound: Bool
    public var toast: Bool
    public var system: Bool

    public init(sound: Bool, toast: Bool, system: Bool) {
        self.sound = sound
        self.toast = toast
        self.system = system
    }

    /// `focused`: the window is visible and has focus (`document.visibilityState === "visible" &&
    /// document.hasFocus()`). `openThread`: the routed thread, environment and id.
    public static func route(_ event: ThreadNotificationEvent, mode: ThreadNotificationMode, inAppEnabled: Bool, focused: Bool,
                             openThread: (environmentId: String, threadId: ThreadId)?, permissionGranted: Bool) -> ThreadNotificationRoute {
        let isOpen = openThread.map { $0.environmentId == event.environmentId && $0.threadId == event.threadId } ?? false
        let toast = inAppEnabled && focused && !isOpen
        let system = !toast && mode.hasDesktopNotifications && !focused && permissionGranted
        return ThreadNotificationRoute(sound: mode.hasSound, toast: toast, system: system)
    }
}

/// Space, removed in 1.14.2, scheduled its reminders under ids that start with "space.". Launch withdraws them so
/// none fires for a page the app can no longer open. Thread notifications use "environment:thread" tags.
public enum SpaceReminderLeftovers {
    public static func ids(_ identifiers: [String]) -> [String] { identifiers.filter { $0.hasPrefix("space.") } }
}
