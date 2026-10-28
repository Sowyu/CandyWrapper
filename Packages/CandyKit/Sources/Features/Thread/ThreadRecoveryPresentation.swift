import Foundation
import T3Protocol
import T3Store

/// threadExecution.ts:392-439, the provider-owned goal displayed above the composer.
public enum ThreadGoalPresentation {
    public static func title(_ goal: ProviderGoal, working: Bool) -> String {
        let labels: [GoalStatus: String] = [.active: working ? "Pursuing goal" : "Goal set", .paused: "Goal paused", .blocked: "Goal blocked",
            .usageLimited: "Goal hit a usage limit", .budgetLimited: "Goal reached its token budget", .complete: "Goal complete"]
        var parts = [labels[goal.status] ?? "Goal set"]
        func tokens(_ value: Int) -> String {
            value < 1_000 ? "\(value)" : value < 1_000_000 ? "\(Int((Double(value) / 1_000).rounded()))k" : ThreadContextWindowUsage.tokens(Double(value))
        }
        if let used = goal.tokensUsed, used > 0 {
            parts.append(tokens(used) + (goal.tokenBudget.map { " / " + tokens($0) } ?? "") + " tokens")
        }
        if let seconds = goal.timeUsedSeconds, seconds >= 60 {
            parts.append(formatDuration(Double(seconds) * 1_000))
        }
        if let checks = goal.checks, checks > 0 { parts.append("\(checks) " + (checks == 1 ? "check" : "checks")) }
        return parts.joined(separator: " · ")
    }
    public static func canResume(_ goal: ProviderGoal) -> Bool { goal.status != .active && goal.status != .complete }
}

/// UsageLimitRecoveryBanner.tsx:21-79. The server preserves options omitted from this update.
public enum ThreadUsageLimitRecovery {
    public static func update(thread: ThreadShell, autoResume: Bool?, snooze: Bool?) -> JSONValue? {
        guard let run = thread.latestRunId, let reset = thread.usageLimitResetAt else { return nil }
        var recovery: [String: JSONValue] = ["runId": .string(run.rawValue), "resetAt": .string(reset.raw)]
        if let autoResume { recovery["autoResume"] = .bool(autoResume) }
        if let snooze { recovery["snooze"] = .bool(snooze) }
        return .object(["type": .string("thread.metadata.update"), "threadId": .string(thread.id.localId.rawValue),
                        "commandId": .string(UUID().uuidString.lowercased()), "limitRecovery": .object(recovery)])
    }
    public static func canSchedule(_ thread: ThreadShell) -> Bool {
        guard let reset = thread.usageLimitResetAt?.date else { return false }
        let stopped = thread.latestRunCompletedAt.value?.date ?? thread.updatedAt.date
        return stopped.map { reset > $0 } ?? false
    }
    /// The server leaves `snoozedUntil` in place after the timer wakes the thread, so a snooze whose
    /// reset has passed no longer counts (UsageLimitRecoveryBanner.tsx:48-58, f416175804).
    public static func snoozed(_ thread: ThreadShell, now: Date = Date()) -> Bool {
        guard let reset = thread.usageLimitResetAt?.date, reset > now else { return false }
        return thread.limitRecovery?.runId == thread.latestRunId && thread.limitRecovery?.resetAt == thread.usageLimitResetAt
            && thread.limitRecovery?.snooze == true && thread.snoozedUntil?.date == reset
    }
    public static func scheduled(_ thread: ThreadShell) -> Bool {
        thread.limitRecovery?.runId == thread.latestRunId && thread.limitRecovery?.resetAt == thread.usageLimitResetAt && thread.limitRecovery?.autoResume == true
    }
}

/// `presentPendingBackgroundWork` (threadExecution.ts:281-357): the background work banner's title and items,
/// subagents first, then commands, monitors and other tasks.
public enum BackgroundWorkPresentation {
    public struct Item: Equatable {
        public var taskId: String
        public var kind: BackgroundTaskKind
        public var label: String
        public var childThreadId: ThreadId?
    }
    public struct Value: Equatable {
        public var title: String
        public var items: [Item]
        /// The work holds the thread's completion, so the dot pulses.
        public var waiting: Bool
    }

    public struct Activity: Equatable {
        public var title: String
        public var detail: String?
        public var startedAt: T3Timestamp?
        public var childThreadId: ThreadId?
        public var commandsOnly: Bool
    }

    /// T3 3814 ThreadActivityBanners.tsx:118-194 joins task ids to the newest subagent progress.
    public static func activity(_ value: Value, turnItems: [TurnItem]) -> Activity {
        let rows = value.items.map { task -> (Item, String?, TurnItem?) in
            let item = turnItems.last { ($0["nativeItemRef"]?["nativeId"]?.stringValue ?? $0.id.rawValue) == task.taskId }
            let progress = item?.type == .subagent ? item?.string("progress")?.split(whereSeparator: \.isWhitespace).joined(separator: " ") : nil
            return (task, progress?.isEmpty == false ? progress : nil, item)
        }
        let only = rows.count == 1 ? rows.first : nil
        let newest = rows.filter { $0.1 != nil }.max { ($0.2?.updatedAt.epochMs ?? 0) < ($1.2?.updatedAt.epochMs ?? 0) }
        let title = only.map { (value.waiting ? "Waiting on " : "Running ") + $0.0.label } ?? value.title
        let detail = only != nil ? only?.1 : newest.map { $0.0.label + ": " + ($0.1 ?? "") } ?? rows.map { $0.0.label }.joined(separator: ", ")
        let start = only?.2?.string("startedAt").map { T3Timestamp($0) }
        let child = only.flatMap { $0.0.childThreadId ?? $0.2?.string("childThreadId").map { ThreadId($0) } }
        return Activity(title: title, detail: detail, startedAt: start, childThreadId: child,
                        commandsOnly: rows.allSatisfy { $0.0.kind != .subagent })
    }

    private static func noun(_ kind: BackgroundTaskKind) -> (order: Int, singular: String, plural: String) {
        switch kind {
        case .subagent: (0, "subagent", "subagents")
        case .command: (1, "command", "commands")
        case .monitor: (2, "monitor", "monitors")
        // An unknown kind decodes as `background_task` in T3.
        default: (3, "background task", "background tasks")
        }
    }

    /// Dither's short label, without the task titles: "Waiting on subagent", "Waiting on 2 commands", or just
    /// "Waiting" when the kinds are mixed.
    public static func shortTitle(_ value: Value) -> String {
        let orders = Set(value.items.map { noun($0.kind).order })
        guard orders.count == 1, let kind = value.items.first?.kind else { return value.waiting ? "Waiting" : "Running" }
        let n = noun(kind), count = value.items.count
        if value.waiting { return "Waiting on " + (count == 1 ? n.singular : "\(count) \(n.plural)") }
        return "Running " + (count == 1 ? "a \(n.singular)" : "\(count) \(n.plural)")
    }

    public static func present(_ tasks: [PendingBackgroundTask], awaitedMarked: Bool = true) -> Value? {
        guard !tasks.isEmpty else { return nil }
        let waiting = SidebarModel.backgroundWorkHoldsCompletion(tasks, awaitedMarked: awaitedMarked)
        let items = tasks.map { task -> Item in
            let description = task.description?.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = task.kind == .subagent && description != nil
                ? ThreadRelationships.subagentDisplayTitle(description!).trimmingCharacters(in: .whitespacesAndNewlines) : description
            return Item(taskId: task.taskId, kind: task.kind, label: label.flatMap { $0.isEmpty ? nil : $0 } ?? noun(task.kind).singular,
                        childThreadId: task.kind == .subagent ? task.childThreadId : nil)
        }.enumerated().sorted { (noun($0.element.kind).order, $0.offset) < (noun($1.element.kind).order, $1.offset) }.map(\.element)
        if items.count == 1, let only = items.first {
            let singular = noun(only.kind).singular
            let named = only.label != singular
            let title = waiting
                ? named ? (only.kind == .monitor ? "" : "Waiting on \(singular) ") + only.label : "Waiting on a \(singular)"
                : named ? "Running: \(only.label)" : "Running a \(singular)"
            return Value(title: title, items: items, waiting: waiting)
        }
        var counts: [(kind: BackgroundTaskKind, count: Int)] = []
        for item in items {
            if let i = counts.firstIndex(where: { noun($0.kind).order == noun(item.kind).order }) { counts[i].count += 1 }
            else { counts.append((item.kind, 1)) }
        }
        let groups = counts.map { "\($0.count) " + ($0.count == 1 ? noun($0.kind).singular : noun($0.kind).plural) }
        let joined = groups.count <= 1 ? groups.joined() : groups.dropLast().joined(separator: ", ") + " and " + groups.last!
        return Value(title: (waiting ? "Waiting on " : "Running ") + joined, items: items, waiting: waiting)
    }
}
