import Foundation
import T3Protocol

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
            parts.append(seconds < 3600 ? "\(seconds / 60)m \(seconds % 60)s" : "\(seconds / 3600)h \(seconds % 3600 / 60)m")
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
    public static func scheduled(_ thread: ThreadShell) -> Bool {
        thread.limitRecovery?.runId == thread.latestRunId && thread.limitRecovery?.resetAt == thread.usageLimitResetAt && thread.limitRecovery?.autoResume == true
    }
}
