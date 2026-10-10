import Foundation
import T3Protocol

// Thread lifecycle actions from the sidebar rows and the thread menu. Paths are relative to the
// pingdotgg/t3code checkout in ../CandyWrapper-research/t3code.

// MARK: - Commands

/// `orchestration.dispatchCommand` payloads (packages/client-runtime/src/operations/commands.ts:433-558).
/// `threadId` is the id the environment's server knows, never a scoped one.
public enum ThreadCommands {
    public static func newCommandId() -> String { UUID().uuidString.lowercased() }

    /// `simpleThreadCommand`: `{type, commandId, threadId}` plus any extra fields.
    static func command(_ type: String, _ threadId: ThreadId, _ commandId: String, _ extra: [String: JSONValue] = [:]) -> JSONValue {
        var fields = extra
        fields["type"] = .string(type)
        fields["commandId"] = .string(commandId)
        fields["threadId"] = .string(threadId.rawValue)
        return .object(fields)
    }

    public static func settle(_ threadId: ThreadId, commandId: String = newCommandId()) -> JSONValue {
        command("thread.settle", threadId, commandId)
    }

    /// `reason: "user"` keeps the thread active until real activity clears it (useThreadActions.ts:670-676).
    public static func unsettle(_ threadId: ThreadId, commandId: String = newCommandId()) -> JSONValue {
        command("thread.unsettle", threadId, commandId, ["reason": .string("user")])
    }

    public static func snooze(_ threadId: ThreadId, until: String, commandId: String = newCommandId()) -> JSONValue {
        command("thread.snooze", threadId, commandId, ["snoozedUntil": .string(until)])
    }

    public static func unsnooze(_ threadId: ThreadId, commandId: String = newCommandId()) -> JSONValue {
        command("thread.unsnooze", threadId, commandId, ["reason": .string("user")])
    }

    /// `orderKey` only when the server decodes it (`threadPinReorder`).
    public static func pin(_ threadId: ThreadId, orderKey: String?, commandId: String = newCommandId()) -> JSONValue {
        command("thread.pin", threadId, commandId, orderKey.map { ["orderKey": .string($0)] } ?? [:])
    }

    public static func unpin(_ threadId: ThreadId, commandId: String = newCommandId()) -> JSONValue {
        command("thread.unpin", threadId, commandId)
    }

    public static func setAutoSettle(_ threadId: ThreadId, enabled: Bool, commandId: String = newCommandId()) -> JSONValue {
        command("thread.auto-settle.set", threadId, commandId, ["enabled": .bool(enabled)])
    }

    public static func markUnread(_ threadId: ThreadId, commandId: String = newCommandId()) -> JSONValue {
        command("thread.mark-unread", threadId, commandId)
    }

    public static func archive(_ threadId: ThreadId, commandId: String = newCommandId()) -> JSONValue {
        command("thread.archive", threadId, commandId)
    }

    public static func unarchive(_ threadId: ThreadId, commandId: String = newCommandId()) -> JSONValue {
        command("thread.unarchive", threadId, commandId)
    }

    /// `updateThreadMetadata` with only `regenerateTitle` (commands.ts:560-585).
    public static func regenerateTitle(_ threadId: ThreadId, commandId: String = newCommandId()) -> JSONValue {
        command("thread.metadata.update", threadId, commandId, ["regenerateTitle": .bool(true)])
    }

    /// The committed sequence from a dispatch result, `{"sequence": n}`.
    public static func sequence(_ result: JSONValue) -> Int? {
        if case .number(let n)? = result["sequence"] { return Int(n) }
        return nil
    }
}

/// `projects.mutate` with `project.create` (commands.ts:341-358), as the add-project flow sends it
/// (CommandPalette.tsx:2465-2474): the folder's name as title, create the folder if missing, no
/// default model.
public enum ProjectCommands {
    public static func create(projectId: ProjectId, workspaceRoot: String, commandId: String = ThreadCommands.newCommandId()) -> JSONValue {
        .object([
            "type": .string("project.create"), "commandId": .string(commandId), "projectId": .string(projectId.rawValue),
            "title": .string(inferTitle(fromPath: workspaceRoot)), "workspaceRoot": .string(workspaceRoot),
            "createWorkspaceRootIfMissing": .bool(true), "defaultModelSelection": .null,
        ])
    }

    /// `inferProjectTitleFromPath` (client-runtime state/projects.ts:148-156): the last non-empty segment.
    public static func inferTitle(fromPath path: String) -> String {
        path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? path
    }

    /// `findProjectByPath`: an environment's project with the same folder, trailing separators ignored.
    public static func existing(_ projects: [ProjectShell], workspaceRoot: String) -> ProjectShell? {
        let target = SidebarModel.normalizeProjectPath(workspaceRoot)
        return projects.first { SidebarModel.normalizeProjectPath($0.workspaceRoot) == target }
    }
}

// MARK: - Optimistic updates

/// What a command does to the thread's shell before the server confirms it
/// (client-runtime state/threadCommands.ts:407-490).
public enum OptimisticThreadUpdate: Sendable, Equatable {
    case settle, unsettle, unsnooze, unpin
    case snooze(until: T3Timestamp)
    case pin(orderKey: String?)
    case setAutoSettle(Bool)

    static let settleBlocking: Set<ThreadStatus> = [.preparing, .queued, .starting, .running, .waiting]
    static let snoozeBlocking: Set<ThreadStatus> = [.preparing, .queued, .starting]

    /// `accepted` is true once the server took the command: the guards against busy threads then stop
    /// applying, because the server already decided.
    public func apply(_ thread: ThreadShell, now: T3Timestamp, accepted: Bool) -> ThreadShell {
        var t = thread
        switch self {
        case .settle:
            if !accepted && (thread.pendingRuntimeRequest != nil || Self.settleBlocking.contains(thread.status)) { return thread }
            t.pendingRuntimeRequest = nil
            t.settledOverride = .settled
            t.settledAt = thread.settledOverride == .settled ? (thread.settledAt ?? now) : now
            t.unsettledAt = nil
            t.activeOrderKey = nil
            t.pinnedAt = nil
            t.pinOrderKey = nil
            t.snoozedAt = nil
            t.snoozedUntil = nil
        case .unsettle:
            t.settledOverride = .active
            t.settledAt = nil
            t.unsettledAt = thread.settledOverride == .active ? thread.unsettledAt : now
        case .snooze(let until):
            let blocked = !accepted && (thread.pendingRuntimeRequest != nil || Self.snoozeBlocking.contains(thread.status))
            guard !blocked, let wake = until.epochMs, let nowMs = now.epochMs, wake > nowMs else { return thread }
            t.pendingRuntimeRequest = nil
            t.snoozedUntil = until
            t.snoozedAt = thread.snoozedUntil?.epochMs == wake ? (thread.snoozedAt ?? now) : now
        case .unsnooze:
            t.snoozedUntil = nil
            t.snoozedAt = nil
        case .setAutoSettle(let enabled):
            t.autoSettleDisabledAt = enabled ? nil : (thread.autoSettleDisabledAt ?? now)
        case .pin(let orderKey):
            t.pinnedAt = thread.pinnedAt ?? now
            t.pinOrderKey = thread.pinnedAt == nil ? orderKey : thread.pinOrderKey
            if thread.settledOverride == .settled {
                t.settledOverride = .active
                t.settledAt = nil
                t.unsettledAt = now
            }
            t.snoozedUntil = nil
            t.snoozedAt = nil
        case .unpin:
            t.pinnedAt = nil
            t.pinOrderKey = nil
        }
        return t
    }
}

/// Pending optimistic updates per environment (`createOptimisticThreadLifecycle`,
/// client-runtime state/threadLifecycle.ts): an update shows at once, goes away if the command
/// fails, and once confirmed stays until that environment's shell reaches the command's sequence.
public struct OptimisticThreadOverlay: Sendable {
    struct Entry: Sendable {
        let token: Int
        let environmentId: String
        let threadId: ThreadId
        let update: OptimisticThreadUpdate
        let now: T3Timestamp
        var sequence: Int?
    }

    private var entries: [Entry] = []
    private var nextToken = 0

    public init() {}

    public var isEmpty: Bool { entries.isEmpty }

    /// Starts an update for `threadId` (the server's id) on `environmentId`. Returns its token.
    public mutating func begin(_ update: OptimisticThreadUpdate, threadId: ThreadId, environmentId: String, now: Date = Date()) -> Int {
        nextToken += 1
        entries.append(Entry(token: nextToken, environmentId: environmentId, threadId: threadId, update: update,
                             now: T3Timestamp(now), sequence: nil))
        return nextToken
    }

    /// The server accepted the command at `sequence`.
    public mutating func confirm(_ token: Int, sequence: Int) {
        if let i = entries.firstIndex(where: { $0.token == token }) { entries[i].sequence = sequence }
    }

    /// The command failed or was dropped.
    public mutating func cancel(_ token: Int) {
        entries.removeAll { $0.token == token }
    }

    /// Drops confirmed updates the environment's shell has caught up with.
    public mutating func reconcile(environmentId: String, snapshotSequence: Int) {
        entries.removeAll { $0.environmentId == environmentId && ($0.sequence.map { snapshotSequence >= $0 } ?? false) }
    }

    /// The environment left the view: its updates go with it.
    public mutating func remove(environmentId: String) {
        entries.removeAll { $0.environmentId == environmentId }
    }

    /// The environment's shell (unscoped) with its pending updates applied in order.
    public func apply(_ snapshot: ShellSnapshot, environmentId: String) -> ShellSnapshot {
        let pending = entries.filter { $0.environmentId == environmentId && ($0.sequence.map { $0 > snapshot.snapshotSequence } ?? true) }
        guard !pending.isEmpty else { return snapshot }
        var out = snapshot
        out.threads = snapshot.threads.map { thread in
            pending.filter { $0.threadId == thread.id }.reduce(thread) { current, e in
                e.update.apply(current, now: e.now, accepted: e.sequence != nil)
            }
        }
        return out
    }
}

// MARK: - Pin order keys

/// Fractional keys for the pinned block (client-runtime state/threadSort.ts:185-231).
public enum PinOrderKey {
    static let digits = Array("abcdefghijklmnopqrstuvwxyz")

    static func isValid(_ key: String) -> Bool {
        !key.isEmpty && key.allSatisfy { digits.contains($0) } && key.last != digits[0]
    }

    static func midpoint(_ a: [Character], _ b: [Character]) -> [Character] {
        if !b.isEmpty {
            var n = 0
            while (n < a.count ? a[n] : digits[0]) == (n < b.count ? b[n] : nil) { n += 1 }
            if n > 0 { return Array(b[..<n]) + midpoint(Array(a.dropFirst(n)), Array(b.dropFirst(n))) }
        }
        let digitA = a.first.flatMap { digits.firstIndex(of: $0) } ?? 0
        let digitB = b.first.flatMap { digits.firstIndex(of: $0) } ?? digits.count
        // JS `Math.round` rounds halves up, as integer division of (sum + 1) does.
        if digitB - digitA > 1 { return [digits[(digitA + digitB + 1) / 2]] }
        if b.count > 1 { return [b[0]] }
        return [digits[digitA]] + midpoint(Array(a.dropFirst()), [])
    }

    /// `pinOrderKeyBetween`: a key that sorts strictly between two neighbors; nil bounds are the ends.
    /// Nil when the neighbors are corrupt or out of order.
    public static func between(_ before: String?, _ after: String?) -> String? {
        let a = before ?? "", b = after ?? ""
        if !a.isEmpty && !isValid(a) { return nil }
        if !b.isEmpty && !isValid(b) { return nil }
        if !b.isEmpty && a >= b { return nil }
        return String(midpoint(Array(a), Array(b)))
    }

    /// `topOfPinnedRunOrderKey` (useThreadActions.ts:113-123): before every keyed pinned thread,
    /// across environments.
    public static func topOfPinnedRun(_ threads: [ThreadShell]) -> String? {
        let first = threads.compactMap { $0.pinnedAt == nil ? nil : $0.pinOrderKey }.min()
        return between(nil, first)
    }
}

// MARK: - Snooze

/// One "snooze until" choice (client-runtime state/threadSettled.ts:217-286).
public struct SnoozePreset: Sendable, Equatable {
    public var id: String
    public var label: String
    /// The menu's time column: "6:00 PM", or "Mon 9:00 AM" for next week.
    public var whenLabel: String
    public var snoozedUntil: Date
    /// `toISOString()`, as the command sends it.
    public var iso: String { T3Timestamp(snoozedUntil).raw }
}

public enum SnoozePresets {
    static let hourMs: TimeInterval = 3600
    static let eveningHour = 18
    static let morningHour = 9

    /// `resolveSnoozePresets` with the web's time labels (apps/web/src/components/Sidebar.snooze.ts):
    /// in 1 hour, in 3 hours, this evening (only while 18:00 is more than an hour away), tomorrow
    /// 9:00, next Monday 9:00 (dropped when it is tomorrow).
    public static func resolve(now: Date, calendar: Calendar = .current, locale: Locale = .current) -> [SnoozePreset] {
        let time = DateFormatter()
        time.locale = locale
        time.calendar = calendar
        time.timeZone = calendar.timeZone
        time.setLocalizedDateFormatFromTemplate("jmm")
        let weekday = DateFormatter()
        weekday.locale = locale
        weekday.calendar = calendar
        weekday.timeZone = calendar.timeZone
        weekday.setLocalizedDateFormatFromTemplate("EEE")

        func at(_ hour: Int, _ base: Date) -> Date {
            calendar.date(bySettingHour: hour, minute: 0, second: 0, of: base) ?? base
        }
        func preset(_ id: String, _ label: String, _ date: Date, weekdayPrefix: Bool = false) -> SnoozePreset {
            let when = time.string(from: date)
            return SnoozePreset(id: id, label: label, whenLabel: weekdayPrefix ? "\(weekday.string(from: date)) \(when)" : when,
                                snoozedUntil: date)
        }
        let inAnHour = now.addingTimeInterval(hourMs)
        let inThreeHours = now.addingTimeInterval(3 * hourMs)
        var presets = [preset("hour", "In 1 hour", inAnHour), preset("three-hours", "In 3 hours", inThreeHours)]
        let evening = at(eveningHour, now)
        if evening.timeIntervalSince(now) > hourMs { presets.append(preset("evening", "This evening", evening)) }
        // Calendar days, not 24 h steps, so DST days land right.
        let tomorrow = at(morningHour, calendar.date(byAdding: .day, value: 1, to: now) ?? now)
        presets.append(preset("tomorrow", "Tomorrow", tomorrow))
        // JS `getDay()`: Sunday is 0. Calendar weekdays start at 1 for Sunday.
        let jsDay = calendar.component(.weekday, from: now) - 1
        let untilMonday = (1 - jsDay + 7) % 7 == 0 ? 7 : (1 - jsDay + 7) % 7
        let nextWeek = at(morningHour, calendar.date(byAdding: .day, value: untilMonday, to: now) ?? now)
        if nextWeek != tomorrow { presets.append(preset("next-week", "Next week", nextWeek, weekdayPrefix: true)) }
        return presets
    }
}

extension SidebarModel {
    /// `QUEUED_TURN_START_GRACE_MS`.
    public static let queuedTurnStartGraceMs: Int64 = 2 * 60 * 1000

    /// `hasQueuedTurnStart` (client-runtime state/threadSettled.ts:51-81): a user message no run has
    /// picked up yet, within the grace window.
    public static func hasQueuedTurnStart(_ thread: SidebarThread, nowMs: Int64) -> Bool {
        if let status = thread.runtime?.status, [.preparing, .queued, .starting].contains(status) { return true }
        guard let messageAt = thread.shell.latestUserMessageAt?.epochMs else { return false }
        if abs(nowMs - messageAt) > queuedTurnStartGraceMs { return false }
        guard let run = thread.latestRun else { return true }
        return [run.requestedAt, run.startedAt, run.completedAt].allSatisfy { t in
            guard let t else { return true }
            guard let ms = t.epochMs else { return false } // NaN < x is false in JS
            return ms < messageAt
        }
    }

    /// `canSnooze` (threadSettled.ts:137-153): never on work blocked on the user or a queued turn.
    public static func canSnooze(_ thread: SidebarThread, nowMs: Int64) -> Bool {
        !thread.hasPendingApprovals && !thread.hasPendingUserInput && !hasQueuedTurnStart(thread, nowMs: nowMs)
    }

    /// `threadRuntimeCanArchive` (client-runtime state/models.ts:70-77): archive refuses a running provider.
    public static func runtimeCanArchive(_ runtime: ThreadRuntimeSummary?) -> Bool {
        if runtime?.status == .queued { return runtime?.activeRunId == nil }
        return ![ThreadStatus.preparing, .starting, .running].contains(runtime?.status ?? .idle)
    }
}

// MARK: - Thread menu

/// One entry of the thread's right-click menu (`ContextMenuItem`).
public struct ThreadMenuItem: Sendable, Equatable {
    public var id: String
    public var label: String
    public var disabled = false
    public var destructive = false
    public var separatorBefore = false
    public var checked: Bool?
    public var children: [ThreadMenuItem] = []

    public init(_ id: String, _ label: String, disabled: Bool = false, destructive: Bool = false, separatorBefore: Bool = false,
                checked: Bool? = nil, children: [ThreadMenuItem] = []) {
        self.id = id; self.label = label; self.disabled = disabled; self.destructive = destructive
        self.separatorBefore = separatorBefore; self.checked = checked; self.children = children
    }
}

/// `buildThreadActionMenuItems` (apps/web/src/components/threadActionMenu.logic.ts:122-270). Native on
/// desktop: Electron builds an NSMenu from these (apps/desktop/src/electron/ElectronMenu.ts:142-190).
public enum ThreadActionMenu {
    public struct State: Sendable {
        public var canOperate = true
        public var branch: String?
        /// The scoped project group, nil where no list sits behind the menu.
        public var projectFilter: (label: String, isActive: Bool)?
        public var isPinned = false
        public var isSettled = false
        public var autoSettleEnabled = true
        public var isSnoozed = false
        public var canSnoozeNow = true
        public var isRegeneratingTitle = false
        public var isRunning = false
        public var supportsSettlement = true
        public var supportsAutoSettleOptOut = true
        public var supportsSnooze = true
        public var supportsPinning = true
        public var supportsTitleRegeneration = true
        public var snoozePresets: [SnoozePreset] = []
        public init() {}
    }

    /// Actions that change the thread; the rest stay open to read-only connections.
    public static func requiresOperate(_ id: String) -> Bool {
        !["new-thread-on-branch", "project-settings", "mark-unread", "copy", "copy-path", "copy-branch", "copy-thread-id"].contains(id)
    }

    public static func items(_ s: State) -> [ThreadMenuItem] {
        var items: [ThreadMenuItem] = []
        if let branch = s.branch { items.append(.init("new-thread-on-branch", "New thread on \(branch)")) }
        if s.supportsPinning { items.append(s.isPinned ? .init("unpin", "Unpin thread") : .init("pin", "Pin thread")) }
        if s.supportsSettlement { items.append(s.isSettled ? .init("unsettle", "Un-settle thread") : .init("settle", "Settle thread")) }
        if s.supportsSnooze {
            if s.isSnoozed {
                items.append(.init("unsnooze", "Wake thread"))
            } else {
                items.append(.init("snooze", "Snooze", disabled: !s.canSnoozeNow,
                                   children: s.snoozePresets.map { .init("snooze:\($0.id)", "\($0.label) (\($0.whenLabel))") }
                                       + [.init("snooze:custom", "Custom…", separatorBefore: true)]))
            }
        }
        items.append(.init("rename", "Rename thread", separatorBefore: true))
        if s.supportsTitleRegeneration {
            items.append(.init("regenerate-title", s.isRegeneratingTitle ? "Regenerating…" : "Regenerate title", disabled: s.isRegeneratingTitle))
        }
        items.append(.init("mark-unread", "Mark unread"))
        if let filter = s.projectFilter {
            items.append(.init("filter-by-project", filter.isActive ? "Show all projects" : "Filter by \(filter.label)"))
        }
        if s.supportsAutoSettleOptOut {
            items.append(.init("auto-settle", "Auto-settle behavior", children: [
                .init("auto-settle:enabled", "Enabled", checked: s.autoSettleEnabled),
                .init("auto-settle:disabled", "Disabled", checked: !s.autoSettleEnabled),
            ]))
        }
        var copy: [ThreadMenuItem] = [.init("copy-path", "Path")]
        if s.branch != nil { copy.append(.init("copy-branch", "Branch")) }
        copy.append(.init("copy-thread-id", "Thread ID"))
        items.append(.init("copy", "Copy", separatorBefore: true, children: copy))
        items.append(.init("project-settings", "Project settings"))
        items.append(.init("archive", "Archive thread", disabled: s.isRunning, separatorBefore: true))
        items.append(.init("delete", "Delete", destructive: true))
        guard !s.canOperate else { return items }
        return items.map { item in
            guard requiresOperate(item.id) else { return item }
            var item = item
            item.disabled = true
            item.children = item.children.map { var c = $0; c.disabled = true; return c }
            return item
        }
    }

    /// The menu without `ids` (actions this client does not have yet), at any depth.
    public static func removing(_ ids: Set<String>, from items: [ThreadMenuItem]) -> [ThreadMenuItem] {
        items.compactMap { item in
            guard !ids.contains(item.id) else { return nil }
            var item = item
            item.children = removing(ids, from: item.children)
            return item
        }
    }
}

// MARK: - Undo

/// The sidebar's undo notice (apps/web/src/hooks/threadUndo.ts and showThreadUndoNotice.ts): each
/// action claims `(kind, thread)`; a later claim of the same kind expires the earlier Undo. Consecutive
/// actions of one kind share a notice ("Settled 2 threads") and undo together. The caller expires
/// everything 5 s after the last `show` (`expireAll`).
@MainActor
public final class ThreadUndoLedger {
    public enum Action: String, Sendable { case settled = "Settled", snoozed = "Snoozed", unpinned = "Unpinned", archived = "Archived" }

    public struct Claim: Sendable, Equatable {
        let key: String
        let token: Int
    }

    struct Entry {
        let action: Action
        let claim: Claim
        let undo: @MainActor () async -> Void
    }

    private var current: [String: Int] = [:]
    private var nextToken = 0
    private var live: [Entry] = []
    /// What the notice shows, nil when there is nothing to undo.
    public private(set) var notice: (action: Action, count: Int)?
    public var onChange: (() -> Void)?

    public init() {}

    static func key(_ kind: String, _ threadKey: String) -> String { kind + "\u{0}" + threadKey }

    public func begin(_ kind: String, _ threadKey: String) -> Claim {
        nextToken += 1
        let claim = Claim(key: Self.key(kind, threadKey), token: nextToken)
        current[claim.key] = claim.token
        refresh()
        return claim
    }

    public func isCurrent(_ claim: Claim) -> Bool { current[claim.key] == claim.token }

    public func finish(_ claim: Claim) {
        guard isCurrent(claim) else { return }
        current[claim.key] = nil
        refresh()
    }

    public func invalidate(_ kind: String, _ threadKey: String) {
        current[Self.key(kind, threadKey)] = nil
        refresh()
    }

    /// Offers Undo for a finished action whose claim is still current. `undo` reports its own failure.
    public func show(_ action: Action, claim: Claim, undo: @escaping @MainActor () async -> Void) {
        guard isCurrent(claim) else { return }
        live.append(Entry(action: action, claim: claim, undo: undo))
        refresh()
    }

    /// Runs the shown group's undos; false when nothing is left to undo.
    @discardableResult
    public func undoLatest() -> Bool {
        guard let latest = live.last else { return false }
        let group = Array(live.reversed().prefix { $0.action == latest.action })
        live.removeAll { e in group.contains { $0.claim == e.claim } }
        // Every claim ends before any undo runs, so a second press cannot restore the group twice.
        for e in group { current[e.claim.key] = nil }
        refresh()
        for e in group { Task { await e.undo() } }
        return !group.isEmpty
    }

    /// The 5 s timeout: nothing can be undone any more.
    public func expireAll() {
        for e in live where isCurrent(e.claim) { current[e.claim.key] = nil }
        live.removeAll()
        refresh()
    }

    private func refresh() {
        live.removeAll { !isCurrent($0.claim) }
        var next: (Action, Int)?
        if let latest = live.last {
            next = (latest.action, live.reversed().prefix { $0.action == latest.action }.count)
        }
        let changed = next?.0 != notice?.action || next?.1 != notice?.count
        notice = next.map { (action: $0.0, count: $0.1) }
        if changed { onChange?() }
    }

    /// "Settled 1 thread," as the notice starts (SidebarThreadUndoNotice.tsx:14-23).
    public static func text(_ action: Action, count: Int) -> String {
        "\(action.rawValue) \(count) thread\(count == 1 ? "" : "s"),"
    }
}
