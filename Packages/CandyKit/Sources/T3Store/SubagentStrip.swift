import Foundation
import T3Protocol

/// Redesign's subagent strip above the composer (after Capy's activity strip, `jb` in its jam-chat bundle,
/// docs/research/capy-subagents.md): the open thread's subagents with their status, newest active first, then the ones
/// that finished in the latest turn. Built from the projection's subagent records (orchestrationV2.ts:698-731), each
/// following its child thread's live run like Lineage does (ThreadRelationshipsControl.tsx:178-200).
public struct SubagentStrip: Sendable, Equatable {
    public enum Status: String, Sendable { case running, waiting, needsInput, done, failed }

    public struct Row: Sendable, Equatable {
        /// The subagent record's node id: the child's latest task.
        public let id: String
        /// Stable across the child's tasks: its thread, or the record when it has none yet.
        public let key: String
        /// Its place among the thread's subagents by first appearance, from 1: "Subagent N".
        public let number: Int
        /// Local id, like the projection's.
        public let childThreadId: ThreadId?
        public let title: String
        public let status: Status
        public let driver: String
        public let providerInstanceId: String
        public let model: String?
        public let canStop: Bool
        public var startedAt: T3Timestamp? = nil
        public var completedAt: T3Timestamp? = nil
        public var label: String { "Subagent \(number)" }
        /// "<1m" or "3m" while it works, in whole minutes so a minute tick keeps it true; its run time once it
        /// finished ("45s", "4m"); nil before it started or when a finished one has no end.
        public func elapsedLabel(nowMs: Int64) -> String? {
            guard let start = startedAt?.epochMs else { return nil }
            if finished {
                guard let end = completedAt?.epochMs else { return nil }
                return ThreadRelationships.compactElapsed(seconds: Double(max(0, end - start)) / 1000)
            }
            let ms = max(0, nowMs - start)
            return ms < 60_000 ? "<1m" : ThreadRelationships.compactElapsed(seconds: Double(ms / 60_000 * 60))
        }
        public var finished: Bool { status == .done || status == .failed }
    }

    public var rows: [Row] = []
    /// Running, waiting or waiting on the user.
    public var activeCount = 0
    /// The thread itself waits on its subagents to finish.
    public var parentWaiting = false
    public init() {}

    /// The pill shows only while a subagent still works or waits.
    public var isVisible: Bool { activeCount > 0 }
    /// "3", or "Waiting on 2" while the thread waits on them.
    public var pillText: String { parentWaiting ? "Waiting on \(activeCount)" : "\(activeCount)" }
    public var accessibilityLabel: String {
        parentWaiting ? "Waiting on \(activeCount) subagent\(activeCount == 1 ? "" : "s")"
            : "\(activeCount) running subagent\(activeCount == 1 ? "" : "s")"
    }

    /// Milliseconds until the first live row's time label turns over: the next whole minute since some live row
    /// started. Nil when no live row has a start, so nothing needs a tick.
    public static func nextTimeChangeMs(rows: [Row], nowMs: Int64) -> Int64? {
        rows.lazy.filter { !$0.finished }.compactMap { $0.startedAt?.epochMs }
            .map { 60_000 - max(0, nowMs - $0) % 60_000 }.min()
    }

    // ponytail: finished rows cap at 6 from the latest turn, older ones stay in Lineage; raise it if users want more
    public static let finishedCap = 6
    private static let active: Set<String> = ["pending", "running", "waiting"]

    /// The runs of the thread's latest turn, whose finished subagents stay listed: the newest run that started and
    /// every run that shares its work start. A wake run for a finished subagent carries the turn's start as
    /// `workStartedAt` (wakeWorkStartedAt, Orchestrator.ts:410-430; orchestrationV2RunWorkStartedAt,
    /// orchestrationV2.ts:571-575), and one T3 queues and cancels before it starts has no start, so neither one ends
    /// the turn. A new user turn has no `workStartedAt` and starts a new one.
    public static func latestTurn(_ runs: [Run]) -> Set<RunId> {
        func work(_ run: Run) -> Int64? { (run.workStartedAt ?? run.startedAt ?? run.requestedAt).epochMs }
        let started = runs.filter { $0.startedAt != nil }
        guard let newest = started.max(by: { $0.ordinal < $1.ordinal }) ?? runs.max(by: { $0.ordinal < $1.ordinal })
        else { return [] }
        guard let turn = work(newest) else { return [newest.id] }
        return Set(started.filter { work($0) == turn }.map(\.id)).union([newest.id])
    }

    /// `subagents` is the projection's records in creation order; `shells` the environment's shells with local ids;
    /// `latestTurn` the runs of the thread's latest turn, whose finished subagents stay listed. A child needs input when
    /// its own run waits on the user or a subagent under it does (`pendingSubagentRequestsByThread`, threadShell.ts:48-89).
    public static func make(subagents: [JSONValue], shells: [ThreadShell], latestTurn: Set<RunId>, parent: ThreadShell?) -> SubagentStrip {
        guard !subagents.isEmpty else { return SubagentStrip() }
        let children = Dictionary(shells.filter { $0.lineage.relationshipToParent == .subagent }.map { ($0.id, $0) },
                                  uniquingKeysWith: { a, _ in a })
        let needsInput = Set(PendingSubagentRequests.byThread(shells).keys)
            .union(children.values.filter { PendingSubagentRequests.request($0) != nil }.map(\.id))
        // One row per child thread: a follow-up task on the same child replaces its row (the user, 2026-10-23), which
        // keeps the number of its first task. A live task outranks a settled one.
        var order: [String] = []
        var latest: [String: ProjectedSubagent] = [:]
        for json in subagents {
            guard let record = ProjectedSubagent(json) else { continue }
            let key = record.childThreadId.map { "thread:" + $0.rawValue } ?? "agent:" + record.id
            if let old = latest[key] {
                if Self.active.contains(old.status) && !Self.active.contains(record.status) { continue }
            } else {
                order.append(key)
            }
            latest[key] = record
        }
        var active: [Row] = [], finished: [Row] = []
        for (index, key) in order.enumerated() {
            guard let record = latest[key] else { continue }
            let child = record.childThreadId.flatMap { children[$0] }
            let agent = record.following(child)
            let live = Self.active.contains(agent.status)
            let status: Status
            if live, let c = agent.childThreadId, needsInput.contains(c) { status = .needsInput }
            else if live { status = agent.status == "waiting" ? .waiting : .running }
            else { status = ["failed", "cancelled", "interrupted", "error"].contains(agent.status) ? .failed : .done }
            let raw = child?.title ?? agent.title
            let row = Row(id: record.id, key: key, number: index + 1, childThreadId: agent.childThreadId,
                          title: ThreadRelationships.subagentDisplayTitle(raw), status: status, driver: agent.driver,
                          providerInstanceId: agent.providerInstanceId, model: agent.model, canStop: canStop(agent),
                          startedAt: agent.startedAt, completedAt: agent.completedAt)
            if live { active.append(row) }
            else if let run = record.runId, latestTurn.contains(run) { finished.append(row) }
        }
        var strip = SubagentStrip()
        strip.rows = active.reversed() + finished.reversed().prefix(finishedCap)
        strip.activeCount = active.count
        if let parent, !active.isEmpty {
            let working: Set<ThreadStatus> = [.preparing, .starting, .running]
            let holds = parent.backgroundTasks.contains { $0.kind == .subagent }
            strip.parentWaiting = parent.activityRunStatus == .waiting || (holds && !working.contains(parent.activityRunStatus ?? parent.status))
        }
        return strip
    }

    /// `canStop` (ThreadRelationshipsControl.tsx:460-470): an app-owned task, or a Claude provider-native one with a
    /// strong native ref, that started and still works.
    static func canStop(_ agent: ProjectedSubagent) -> Bool {
        let stoppable = agent.origin == "app_owned" || (agent.origin == "provider_native" && agent.driver == "claudeAgent"
            && agent.runId != nil && agent.nativeTaskStrong && Self.active.contains(agent.nativeStatus ?? agent.status))
        return stoppable && agent.startedAt != nil && Self.active.contains(agent.status)
    }
}
