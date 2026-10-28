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

    public static func reorder(_ threadId: ThreadId, pinned: Bool, orderKey: String, commandId: String = newCommandId()) -> JSONValue {
        command(pinned ? "thread.pin.reorder" : "thread.active.reorder", threadId, commandId, ["orderKey": .string(orderKey)])
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

    /// `updateThreadMetadata` with a new title (Sidebar.tsx:3261-3290).
    public static func rename(_ threadId: ThreadId, title: String, commandId: String = newCommandId()) -> JSONValue {
        command("thread.metadata.update", threadId, commandId, ["title": .string(title)])
    }

    public static func delete(_ threadId: ThreadId, commandId: String = newCommandId()) -> JSONValue {
        command("thread.delete", threadId, commandId)
    }

    /// `closeGuestShare` (commands.ts:437-442): Stop sharing.
    public static func closeGuestShare(_ threadId: ThreadId, commandId: String = newCommandId()) -> JSONValue {
        command("thread.guest-share.close", threadId, commandId)
    }

    /// `resolveGuestMessage` (commands.ts:444-474). Dismiss names the message; Send dispatches it with empty
    /// text and no attachments, because the server fills in the guest's text and files.
    public static func resolveGuestMessage(_ threadId: ThreadId, guestMessageId: String, send: Bool,
                                           commandId: String = newCommandId()) -> JSONValue {
        guard send else {
            return command("thread.guest-message.dismiss", threadId, commandId, ["guestMessageId": .string(guestMessageId)])
        }
        return command("message.dispatch", threadId, commandId, [
            "messageId": .string(commandId), "guestMessageId": .string(guestMessageId), "text": .string(""),
            "attachments": .array([]), "dispatchMode": .object(["type": .string("queue_after_active")]),
            "createdBy": .string("user"), "creationSource": .string("web"),
        ])
    }

    /// `guestShare.create`'s input (guestShare.ts:58).
    public static func createGuestShare(_ threadId: ThreadId) -> JSONValue {
        .object(["threadId": .string(threadId.rawValue)])
    }

    /// `stopThreadSession` (client-runtime operations/commands.ts:919-935): one `provider-session.detach`
    /// per provider session, each with `<commandId>:detach:<sessionId>`.
    public static func detachSessions(_ threadId: ThreadId, sessionIds: [String], commandId: String = newCommandId()) -> [JSONValue] {
        sessionIds.map { id in
            command("provider-session.detach", threadId, "\(commandId):detach:\(id)",
                    ["providerSessionId": .string(id), "reason": .string("client-requested")])
        }
    }

    /// The committed sequence from a dispatch result, `{"sequence": n}`.
    public static func sequence(_ result: JSONValue) -> Int? {
        result["sequence"]?.intValue
    }
}

/// `projects.mutate` with `project.create` (commands.ts:341-358), as the add-project flow sends it
/// (CommandPalette.tsx:2465-2474): the folder's name as title, create the folder if missing, no
/// default model.
public enum ProjectCommands {
    public static func create(projectId: ProjectId, workspaceRoot: String, createWorkspaceRootIfMissing: Bool = true, title: String? = nil, commandId: String = ThreadCommands.newCommandId()) -> JSONValue {
        .object([
            "type": .string("project.create"), "commandId": .string(commandId), "projectId": .string(projectId.rawValue),
            "title": .string(title ?? inferTitle(fromPath: workspaceRoot)), "workspaceRoot": .string(workspaceRoot),
            "createWorkspaceRootIfMissing": .bool(createWorkspaceRootIfMissing), "defaultModelSelection": .null,
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
    case reorder(pinned: Bool, orderKey: String)

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
            // Restamp even for the same wake time, so a re-snooze after a wake hides the thread again
            // (threadCommands.ts:446, T3 699c1c5d4c).
            t.snoozedAt = now
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
        case .reorder(let pinned, let key):
            if pinned { t.pinOrderKey = key } else { t.activeOrderKey = key }
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

    /// threadSort.ts:233-310. Materialize keyless sections, preserving keys reserved by hidden rows.
    public static func assignments(order: [ThreadId], keys: [ThreadId: String], moved: ThreadId) -> [(id: ThreadId, key: String)] {
        guard let index = order.firstIndex(of: moved) else { return [] }
        let visible = Set(order), reserved = Set(keys.filter { !visible.contains($0.key) }.map(\.value))
        let before = index > 0 ? keys[order[index - 1]] : nil
        let after = index + 1 < order.count ? keys[order[index + 1]] : nil
        if (index == 0 || before != nil) && (index + 1 == order.count || after != nil) {
            var key = between(before, after)
            while let current = key, reserved.contains(current) { key = between(current, after) }
            if let key { return [(moved, key)] }
        }
        let count = order.count + reserved.count
        var width = 2, space = 676
        while space <= (count + 1) * 2 { width += 1; space *= 26 }
        let step = Double(space) / Double(count + 1)
        let spread: [String] = (0..<count).map { i in
            var value = Int((step * Double(i + 1)).rounded())
            if value % 26 == 0 { value += 1 }
            var key = ""
            for _ in 0..<width { key.insert(digits[value % 26], at: key.startIndex); value /= 26 }
            return key
        }.filter { !reserved.contains($0) }
        return zip(order, spread).compactMap { id, key in keys[id] == key ? nil : (id, key) }
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
    /// `sortSnoozeRows` (SnoozePresetsSettings.logic.ts:19-40, T3 3824 #26427): the editor's row order, soonest wake
    /// first, options with no wake right now (a passed "Today") last, ties in their current order.
    public static func soonestFirst(_ presets: [SnoozePresetSetting], now: Date, calendar: Calendar = .current) -> [Int] {
        let wakes = presets.map { resolve($0, now: now, calendar: calendar)?.snoozedUntil }
        return presets.indices.sorted { a, b in
            switch (wakes[a], wakes[b]) {
            case let (x?, y?): x != y ? x < y : a < b
            case (_?, nil): true
            case (nil, _?): false
            case (nil, nil): a < b
            }
        }
    }

    /// `sameSnoozePresets` (SnoozePresetsSettings.tsx:93-101): row order is only display order.
    public static func same(_ a: [SnoozePresetSetting], _ b: [SnoozePresetSetting]) -> Bool {
        a.map(\.id).sorted() == b.map(\.id).sorted()
    }

    /// threadSettled.ts:201-329 (3814): sort and deduplicate by wake minute, preserving settings order on ties.
    public static func resolve(now: Date, calendar: Calendar = .current, locale: Locale = TimestampFormat.t3Locale,
                               presets: [SnoozePresetSetting] = SnoozePresetSetting.defaults) -> [SnoozePreset] {
        var seen = Set<Int64>()
        return presets.enumerated().compactMap { index, setting in
            resolve(setting, now: now, calendar: calendar, locale: locale).map { (index, $0) }
        }.sorted {
            let a = Int64($0.1.snoozedUntil.timeIntervalSince1970 / 60)
            let b = Int64($1.1.snoozedUntil.timeIntervalSince1970 / 60)
            return a == b ? $0.0 < $1.0 : a < b
        }.compactMap { _, preset in
            seen.insert(Int64(preset.snoozedUntil.timeIntervalSince1970 / 60)).inserted ? preset : nil
        }
    }

    public static func resolve(_ setting: SnoozePresetSetting, now: Date, calendar: Calendar = .current,
                               locale: Locale = TimestampFormat.t3Locale) -> SnoozePreset? {
        let wake: Date, label: String
        var labelNamesDay = false
        switch setting {
        case .after(let minutes):
            guard (1...SnoozePresetSetting.maximumMinutes).contains(minutes) else { return nil }
            wake = now.addingTimeInterval(Double(minutes) * 60)
            let unit = minutes % 1440 == 0 ? "day" : minutes % 60 == 0 ? "hour" : "minute"
            let n = minutes / (unit == "day" ? 1440 : unit == "hour" ? 60 : 1)
            label = "In \(n) \(unit)" + (n == 1 ? "" : "s")
        case .at(let day, let time):
            guard let dayIndex = SnoozePresetSetting.days.firstIndex(of: day),
                  SnoozePresetSetting(setting.json) != nil else { return nil }
            let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
            let days: Int
            if dayIndex < 2 { days = dayIndex } else {
                let delta = ((weekdays.firstIndex(of: day) ?? 0) - (calendar.component(.weekday, from: now) - 1) + 7) % 7
                days = delta == 0 ? 7 : delta
            }
            let parts = time.split(separator: ":").compactMap { Int($0) }
            guard let date = calendar.date(byAdding: .day, value: days, to: now) else { return nil }
            var components = calendar.dateComponents([.year, .month, .day], from: date)
            components.hour = parts[0]; components.minute = parts[1]; components.second = 0
            // JS setHours preserves the minute when a spring clock change skips this local hour.
            guard let target = calendar.date(from: components), target > now else { return nil }
            wake = target
            if days == 0 { label = parts[0] < 12 ? "This morning" : parts[0] < 17 ? "This afternoon" : "This evening" }
            else if days == 1 { label = "Tomorrow" }
            else if day == "monday" { label = "Next week" }
            else { label = (days == 7 ? "Next " : "") + day.capitalized }
            labelNamesDay = label != "Next week"
        }
        let time = DateFormatter()
        time.locale = locale; time.calendar = calendar; time.timeZone = calendar.timeZone
        time.setLocalizedDateFormatFromTemplate("jmm")
        let formatted = time.string(from: wake).replacingOccurrences(of: "\u{202F}", with: " ")
        time.setLocalizedDateFormatFromTemplate("EEE")
        let when = labelNamesDay || calendar.isDate(now, inSameDayAs: wake) ? formatted : "\(time.string(from: wake)) \(formatted)"
        return SnoozePreset(id: setting.id, label: label, whenLabel: when, snoozedUntil: wake)
    }

    /// Durations start at selection. Absolute choices retain their shown date and reject expired times.
    public static func pick(shown: [SnoozePreset], id: String, now: Date,
                            presets: [SnoozePresetSetting] = SnoozePresetSetting.defaults,
                            calendar: Calendar = .current, locale: Locale = TimestampFormat.t3Locale) -> SnoozePreset? {
        guard let original = shown.first(where: { $0.id == id }) else { return nil }
        if let setting = presets.first(where: { $0.id == id }), case .after = setting {
            return resolve(setting, now: now, calendar: calendar, locale: locale)
        }
        return original.snoozedUntil > now ? original : nil
    }

}

/// The custom snooze dialog's input (`CustomSnoozeInput`, threadSettled.ts:321-354).
public enum CustomSnooze {
    public enum Unit: String, Sendable, CaseIterable { case minutes, hours, days }
    case date(day: String, time: String)
    case duration(amount: String, unit: Unit)

    /// `resolveCustomSnooze`: the wake time, nil for a past or invalid local date or a non-positive duration.
    /// A date that rolls over or a local time a DST change skips is rejected.
    public func resolve(now: Date, calendar: Calendar = .current) -> Date? {
        let wake: Date
        switch self {
        case .duration(let amount, let unit):
            guard let n = Double(amount.trimmingCharacters(in: .whitespaces)), n.isFinite, n > 0 else { return nil }
            let unitSeconds: Double = switch unit { case .minutes: 60; case .hours: 3600; case .days: 86_400 }
            wake = now.addingTimeInterval(n * unitSeconds)
        case .date(let day, let time):
            let d = day.split(separator: "-").map(String.init), t = time.split(separator: ":").map(String.init)
            guard d.count == 3, t.count == 2, d[0].count == 4, d[1].count == 2, d[2].count == 2, t[0].count == 2, t[1].count == 2,
                  let y = Int(d[0]), let m = Int(d[1]), let dd = Int(d[2]), let h = Int(t[0]), let mi = Int(t[1]),
                  let date = calendar.date(from: DateComponents(year: y, month: m, day: dd, hour: h, minute: mi)),
                  Self.localDate(date, calendar: calendar) == day, Self.localTime(date, calendar: calendar) == time else { return nil }
            wake = date
        }
        return wake > now ? wake : nil
    }

    /// `localSnoozeDate`: `YYYY-MM-DD`.
    public static func localDate(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// `localSnoozeTime`: `HH:MM`.
    public static func localTime(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}

extension SidebarModel {
    /// `getOrphanedWorktreePathForThread` (worktreeCleanup.ts:11-33): the thread's worktree when no other
    /// thread in `threads` uses it.
    public static func orphanedWorktreePath(_ threads: [ThreadShell], threadId: ThreadId) -> String? {
        func normalize(_ path: String?) -> String? {
            guard let t = path?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
            return t
        }
        guard let target = threads.first(where: { $0.id == threadId }), let path = normalize(target.worktreePath) else { return nil }
        return threads.contains { $0.id != threadId && normalize($0.worktreePath) == path } ? nil : path
    }

    /// `formatWorktreePathForDisplay`: the last path component.
    public static func worktreeDisplayName(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return path }
        var normalized = trimmed.replacingOccurrences(of: "\\", with: "/")
        while normalized.hasSuffix("/") { normalized.removeLast() }
        let last = normalized.split(separator: "/", omittingEmptySubsequences: false).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return last.isEmpty ? trimmed : last
    }

    /// `getFallbackThreadIdAfterDelete` (Sidebar.logic.ts:1262-1288): the newest other thread of the
    /// same project that is not being deleted.
    public static func fallbackThreadAfterDelete(_ threads: [ThreadShell], deleted: ThreadId, deleting: Set<ThreadId> = [],
                                                 order: SortOrder = .updatedAt) -> ThreadId? {
        guard let thread = threads.first(where: { $0.id == deleted }) else { return nil }
        return threads.filter { $0.projectId == thread.projectId && $0.id != deleted && !deleting.contains($0.id) }
            .max { l, r in
                let lt = getThreadSortTimestamp(l, order), rt = getThreadSortTimestamp(r, order)
                return lt != rt ? lt < rt : l.id.rawValue < r.id.rawValue // `sortThreads`: newest, then the larger id
            }?.id
    }

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

    /// `canSnooze` (threadSettled.ts:141-159): never on work blocked on the user, a subagent's included, or a queued turn.
    public static func canSnooze(_ thread: SidebarThread, nowMs: Int64) -> Bool {
        !thread.hasPendingApprovals && !thread.hasPendingUserInput && thread.pendingSubagentRequest == nil
            && !hasQueuedTurnStart(thread, nowMs: nowMs)
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
    /// One line under the label and as its tooltip, saying what the item does.
    public var detail: String?

    public init(_ id: String, _ label: String, disabled: Bool = false, destructive: Bool = false, separatorBefore: Bool = false,
                checked: Bool? = nil, children: [ThreadMenuItem] = [], detail: String? = nil) {
        self.id = id; self.label = label; self.disabled = disabled; self.destructive = destructive
        self.separatorBefore = separatorBefore; self.checked = checked; self.children = children; self.detail = detail
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
        /// Guest links need their own grant and the server's beta, so the caller checks them instead of `canOperate`
        /// (threadActionMenu.logic.ts:90-91, guestShareAvailability.ts).
        public var canShareWithGuest = false
        public init() {}
    }

    /// Actions that change the thread; the rest stay open to read-only connections.
    public static func requiresOperate(_ id: String) -> Bool {
        !["new-thread-on-branch", "project-settings", "mark-unread", "share-guest", "copy", "copy-path", "copy-branch", "copy-thread", "copy-thread-id"].contains(id)
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
        if s.canShareWithGuest { items.append(.init("share-guest", "Share with guest")) }
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
        copy.append(.init("copy-thread", "Thread"))
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

    /// The multi-select menu (Sidebar.tsx:4242-4352): counts cover only the threads each action touches.
    /// `count` is every selected thread with a row; `canSnooze` is true when all of them can snooze now.
    public static func bulkItems(count: Int, pinnedCount: Int, settlingCount: Int, canSnooze: Bool,
                                 titleSupportedCount: Int, titleActionableCount: Int, canOperate: Bool = true,
                                 snoozePresets: [SnoozePreset]) -> [ThreadMenuItem] {
        var items: [ThreadMenuItem] = []
        // `buildBulkUnpinContextMenuItem`: only when something selected is pinned.
        if pinnedCount > 0 { items.append(.init("unpin", "Unpin (\(pinnedCount))", disabled: !canOperate)) }
        items.append(.init("settle", "Settle (\(count))", disabled: settlingCount == 0 || !canOperate))
        if canSnooze {
            items.append(.init("snooze", "Snooze (\(count))", disabled: !canOperate,
                               children: snoozePresets.map { .init("snooze:\($0.id)", "\($0.label) (\($0.whenLabel))", disabled: !canOperate) }
                                   + [.init("snooze:custom", "Custom…", disabled: !canOperate, separatorBefore: true)]))
        }
        // `buildBulkTitleRegenerationContextMenuItem`.
        if titleSupportedCount > 0 {
            items.append(titleActionableCount == 0
                ? .init("regenerate-title", "Regenerating… (\(titleSupportedCount))", disabled: true)
                : .init("regenerate-title", "Regenerate titles (\(titleActionableCount))", disabled: !canOperate))
        }
        items.append(.init("mark-unread", "Mark unread (\(count))"))
        items.append(.init("delete", "Delete (\(count))", disabled: !canOperate, destructive: true))
        return items
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
    /// A new notice owns Mod+Z even inside a text field until the user presses another key or edits text.
    /// After that Mod+Z is the field's own undo again (showThreadUndoNotice.ts in 3473, 21da3061aa).
    private var shortcutClaimed = false
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
        shortcutClaimed = true
        refresh()
    }

    /// Whether Mod+Z should undo the notice's actions even while a text field has focus (`threadUndoClaimsShortcut`).
    public var claimsShortcut: Bool { shortcutClaimed && notice != nil }

    /// Any other keypress or text edit hands Mod+Z back to text fields (`releaseThreadUndoShortcut`).
    public func releaseShortcut() { shortcutClaimed = false }

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
