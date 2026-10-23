import Foundation
import T3Protocol

/// Redesign's subagent strip above the composer (after Capy's activity strip, `jb` in its jam-chat bundle,
/// docs/research/capy-subagents.md): the open thread's subagents with their status, newest active first, then the ones
/// that finished in the latest turn. Built from the projection's subagent records (orchestrationV2.ts:698-731), each
/// following its child thread's live run like Lineage does (ThreadRelationshipsControl.tsx:178-200).
public struct SubagentStrip: Sendable, Equatable {
    public enum Status: String, Sendable { case running, waiting, needsInput, done, failed }

    public struct Row: Sendable, Equatable {
        /// The subagent record's node id.
        public let id: String
        /// Its place among the thread's subagents, from 1: "Subagent N".
        public let number: Int
        /// Local id, like the projection's.
        public let childThreadId: ThreadId?
        public let title: String
        public let status: Status
        public let driver: String
        public let providerInstanceId: String
        public let model: String?
        public let canStop: Bool
        public var label: String { "Subagent \(number)" }
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

    // ponytail: finished rows cap at 6 from the latest turn, older ones stay in Lineage; raise it if users want more
    public static let finishedCap = 6
    private static let active: Set<String> = ["pending", "running", "waiting"]

    /// `subagents` is the projection's records in creation order; `shells` the environment's shells with local ids;
    /// `latestRunId` the thread's newest run, whose finished subagents stay listed. A child needs input when its own run
    /// waits on the user or a subagent under it does (`pendingSubagentRequestsByThread`, threadShell.ts:48-89).
    public static func make(subagents: [JSONValue], shells: [ThreadShell], latestRunId: RunId?, parent: ThreadShell?) -> SubagentStrip {
        guard !subagents.isEmpty else { return SubagentStrip() }
        let children = Dictionary(shells.filter { $0.lineage.relationshipToParent == .subagent }.map { ($0.id, $0) },
                                  uniquingKeysWith: { a, _ in a })
        let needsInput = Set(PendingSubagentRequests.byThread(shells).keys)
            .union(children.values.filter { PendingSubagentRequests.request($0) != nil }.map(\.id))
        var active: [Row] = [], finished: [Row] = []
        for (index, json) in subagents.enumerated() {
            guard let record = ProjectedSubagent(json) else { continue }
            let child = record.childThreadId.flatMap { children[$0] }
            let agent = record.following(child)
            let live = Self.active.contains(agent.status)
            let status: Status
            if live, let c = agent.childThreadId, needsInput.contains(c) { status = .needsInput }
            else if live { status = agent.status == "waiting" ? .waiting : .running }
            else { status = ["failed", "cancelled", "interrupted", "error"].contains(agent.status) ? .failed : .done }
            let raw = child?.title ?? agent.title
            let row = Row(id: record.id, number: index + 1, childThreadId: agent.childThreadId,
                          title: ThreadRelationships.subagentDisplayTitle(raw), status: status, driver: agent.driver,
                          providerInstanceId: agent.providerInstanceId, model: agent.model, canStop: canStop(agent))
            if live { active.append(row) }
            else if latestRunId != nil, record.runId == latestRunId { finished.append(row) }
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
