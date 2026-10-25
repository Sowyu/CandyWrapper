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

    /// "Thread completed", "Approval needed", "Usage limit reached", "Thread failed" or "Input needed".
    public var title: String {
        if kind == .completion { return "Thread completed" }
        switch status {
        case .approval: return "Approval needed"
        case .limited: return "Usage limit reached"
        case .failed: return "Thread failed"
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

/// `EnvironmentNotifications`' diff over one environment's live shell (ThreadNotificationCoordinator.tsx:97-280)
/// and `createThreadNotificationGate` (ThreadNotificationCoordinator.logic.ts:19-82). A thread seen for the first
/// time never notifies, so connecting to a server with finished threads is quiet. Attention notifies at once.
/// Completion waits out the Working shelf's exit grace, because an orchestrator run can end moments before its
/// continuation starts; `scan` holds it and `flush` delivers it once due, unless the thread stopped being settled.
public struct ThreadNotificationTracker: Sendable {
    struct State: Sendable {
        var raw: ThreadShell
        var subagentRequest: PendingSubagentRequest?
        var attention: String?
        var settled: Bool
        var completedAt: Int64?
    }

    struct Pending: Sendable {
        var at: Int64
        var dueMs: Int64
        var event: ThreadNotificationEvent
    }

    struct Gate: Sendable {
        var pending: [ThreadId: Pending] = [:]
        /// The newest completion already notified, or deliberately skipped.
        var handled: [ThreadId: Int64] = [:]
        /// The newest completion seen settled, kept while the thread works or waits.
        var lastSettled: [ThreadId: Int64] = [:]

        mutating func skip(_ id: ThreadId, _ at: Int64?) {
            if let at, at > (handled[id] ?? .min) { handled[id] = at }
        }
    }

    private var previous: [String: [ThreadId: State]] = [:]
    private var gates: [String: Gate] = [:]

    public init() {}

    /// The environment's shell is not live (or left): forget it, like `previous.current.clear()` and `gate.clear()`.
    public mutating func reset(environmentId: String) {
        previous[environmentId] = nil
        gates[environmentId] = nil
    }

    public mutating func resetAll() {
        previous = [:]
        gates = [:]
    }

    /// When the next held completion is due, or nil while none is held.
    public var nextDueMs: Int64? { gates.values.flatMap { $0.pending.values.map(\.dueMs) }.min() }

    /// The held completions due by `nowMs`, which count as notified.
    public mutating func flush(nowMs: Int64) -> [ThreadNotificationEvent] {
        var events: [ThreadNotificationEvent] = []
        for env in gates.keys.sorted() {
            guard var gate = gates[env] else { continue }
            for (id, p) in gate.pending.sorted(by: { $0.value.dueMs < $1.value.dueMs }) where p.dueMs <= nowMs {
                gate.pending[id] = nil
                gate.handled[id] = p.at
                events.append(p.event)
            }
            gates[env] = gate
        }
        return events
    }

    /// Diffs the environment's live threads against the last scan and returns the attention notifications due
    /// now. Completions wait in `flush`.
    public mutating func scan(environmentId: String, threads: [ThreadShell], nowMs: Int64) -> [ThreadNotificationEvent] {
        let before = previous[environmentId] ?? [:]
        var gate = gates[environmentId] ?? Gate()
        var next: [ThreadId: State] = [:]
        var changed: [(prior: State?, state: State, status: SidebarThreadStatus)] = []
        // Subagents are skipped below, so their requests notify through the thread above them (T3 f4df794777).
        let subagentRequests = PendingSubagentRequests.byThread(threads)
        for raw in threads {
            if raw.lineage.relationshipToParent == .subagent { continue }
            let prior = before[raw.id]
            let subagentRequest = subagentRequests[raw.id]
            // An unchanged thread can't produce a new notification.
            if let prior, prior.raw == raw, prior.subagentRequest == subagentRequest {
                next[raw.id] = prior
                continue
            }
            let thread = SidebarThread(raw, pendingSubagentRequest: subagentRequest)
            var status = SidebarModel.resolveSidebarThreadStatus(thread)
            if status == .ready, thread.latestRun?.status == .failed { status = .failed }
            let attention: String? = [.input, .approval, .failed, .limited].contains(status)
                ? "\(thread.latestRun?.runId.rawValue ?? ""):\(status.rawValue)" : nil
            // Commands left running (a dev server) read as ready; subagents and awaited work wait.
            let settled = status == .ready && thread.latestRun?.status == .completed
            let state = State(raw: raw, subagentRequest: subagentRequest, attention: attention, settled: settled,
                              completedAt: settled ? thread.latestRun?.completedAt?.epochMs : nil)
            next[raw.id] = state
            changed.append((prior, state, status))
        }
        previous[environmentId] = next
        // `retain`: forget threads that left the snapshot.
        gate.pending = gate.pending.filter { next[$0.key] != nil }
        gate.handled = gate.handled.filter { next[$0.key] != nil }
        gate.lastSettled = gate.lastSettled.filter { next[$0.key] != nil }
        var events: [ThreadNotificationEvent] = []
        for (prior, state, status) in changed {
            let id = state.raw.id
            let archived = state.raw.archivedAt != nil
            // A run the user stopped or a compaction T3 Code started doesn't announce itself
            // (ThreadNotificationCoordinator.tsx:271-277). Failures still do, through `attention`.
            let quiet = state.raw.latestRunStopRequested == true || state.raw.latestRunSilent == true
            if state.settled, let at = state.completedAt { gate.lastSettled[id] = at }
            if !state.settled || archived || quiet { gate.pending[id] = nil }
            // The first sighting, archived threads, and stopped runs never notify completion.
            if prior == nil || archived || quiet { gate.skip(id, state.completedAt) }
            guard let prior, !archived else { continue }
            let event = ThreadNotificationEvent(environmentId: environmentId, threadId: id, threadTitle: state.raw.title,
                                                kind: .input, status: status)
            if let attention = state.attention, attention != prior.attention {
                // Attention replaces the completion before it, so that run must not notify later.
                gate.skip(id, gate.lastSettled[id])
                gate.pending[id] = nil
                events.append(event)
                continue
            }
            guard state.settled, let at = state.completedAt, at > (gate.handled[id] ?? .min) else { continue }
            if gate.pending[id]?.at == at { continue }
            gate.pending[id] = Pending(at: at, dueMs: nowMs + SidebarInboxReturnTracker.workingExitGraceMs,
                                       event: ThreadNotificationEvent(environmentId: environmentId, threadId: id,
                                                                      threadTitle: state.raw.title, kind: .completion, status: status))
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
