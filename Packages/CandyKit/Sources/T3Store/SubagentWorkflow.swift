import Foundation
import T3Protocol

/// A Claude workflow coordinator's run, grouped by phase the way Lineage shows it. Servers from 2994
/// put `workflow: {phases, agents, ...}` on the coordinator subagent (b9afba59f, contracts
/// orchestrationV2.ts:660-745); older servers never send it. Ported from `workflowMembersToRuntime`
/// and `deriveWorkflowGroups` (client-runtime state/subagentRuntime.ts:144-200, 262-320).
public struct SubagentWorkflowGroup: Sendable, Equatable {
    public struct Member: Sendable, Equatable {
        public let id: String
        public let title: String
        public let model: String?
        public let status: String
        public let childThreadId: ThreadId?
        public let agentIndex: Int
        public let phaseIndex: Int?
        public let phaseTitle: String?
        public let startedAt: T3Timestamp?
        public let completedAt: T3Timestamp?
        /// The member's prompt; `result` or `error` is its answer.
        public let progress: String?
        public let result: String?
        public let error: String?
    }

    public struct Phase: Sendable, Equatable {
        public let index: Int
        public let title: String
        public let members: [Member]
        /// `done` once every member settled, `running` while any is active or idle.
        public let state: String
        public let settledCount: Int

        /// `phaseStatusLabel` (ThreadLineageWorkflowRow.tsx:45-54).
        public var statusLabel: String {
            if state == "running" { return "running" }
            if members.contains(where: { $0.status == "failed" }) { return "failed" }
            if members.contains(where: { $0.status == "cancelled" || $0.status == "interrupted" }) { return "stopped" }
            return state == "done" ? "done" : "not started"
        }

        /// `phaseElapsed` (:27-42): members run in parallel, so the phase spans first start to last finish.
        public var elapsed: (status: String, startedAt: T3Timestamp?, completedAt: T3Timestamp?) {
            let running = state == "running"
            let starts = members.compactMap(\.startedAt).sorted { $0.raw < $1.raw }
            let ends = members.compactMap(\.completedAt).sorted { $0.raw < $1.raw }
            let completed = running ? nil : ends.last
            return (running ? "running" : "completed", running || completed != nil ? starts.first : nil, completed)
        }
    }

    /// The coordinator subagent's id, for `orchestration.stopWorkflow`.
    public let coordinatorId: String
    /// `workflow.name`, which Lineage shows in place of the child thread's title.
    public let name: String?
    /// The coordinator's status: the row's status, and members still queued or running take it once it settles.
    public let status: String
    public let phases: [Phase]
    /// Members with no phase, listed after the phases.
    public let unphased: [Member]

    private static let terminal: Set<String> = ["completed", "failed", "cancelled", "interrupted"]

    /// nil when the subagent carries no workflow (every subagent on servers before 2994).
    public init?(coordinator json: JSONValue) {
        guard let workflow = json["workflow"], workflow.objectValue != nil,
              let id = json["id"]?.stringValue, let status = json["status"]?.stringValue else { return nil }
        coordinatorId = id
        name = workflow["name"]?.stringValue
        self.status = status
        let coordinatorCompleted = json["completedAt"]?.stringValue.map { T3Timestamp($0) }
        func iso(_ ms: Double?) -> T3Timestamp? { ms.map { T3Timestamp(Date(timeIntervalSince1970: $0 / 1000)) } }
        let members: [Member] = (workflow["agents"]?.arrayValue ?? []).compactMap { a in
            guard let index = a["index"]?.intValue, let label = a["label"]?.stringValue, let state = a["state"]?.stringValue else { return nil }
            // Every member state but queued is already a runtime status; a settled coordinator settles the rest.
            let memberStatus = (state == "queued" || state == "running") && Self.terminal.contains(status) ? status
                : state == "queued" ? "pending" : state
            let failed = memberStatus == "failed"
            let started = a["startedAt"]?.doubleValue
            let duration = a["durationMs"]?.doubleValue
            let completed: T3Timestamp? = Self.terminal.contains(memberStatus)
                ? (started != nil && duration != nil ? iso(started! + duration!) : coordinatorCompleted) : nil
            return Member(id: "\(id):agent:\(index)", title: label, model: a["model"]?.stringValue, status: memberStatus,
                          childThreadId: a["childThreadId"]?.stringValue.map { ThreadId($0) }, agentIndex: index,
                          phaseIndex: a["phaseIndex"]?.intValue, phaseTitle: a["phaseTitle"]?.stringValue, startedAt: iso(started), completedAt: completed,
                          progress: a["prompt"]?.stringValue, result: failed ? nil : a["result"]?.stringValue,
                          error: failed ? a["result"]?.stringValue : nil)
        }
        // Members seed the phase titles; the declared plan then overwrites them, since it lags the members.
        var titles: [Int: String] = [:]
        for m in members {
            guard let p = m.phaseIndex else { continue }
            titles[p] = m.phaseTitle ?? titles[p] ?? "Phase \(p + 1)"
        }
        for phase in workflow["phases"]?.arrayValue ?? [] {
            if let i = phase["index"]?.intValue, let t = phase["title"]?.stringValue { titles[i] = t }
        }
        phases = titles.keys.sorted().map { index in
            let list = members.filter { $0.phaseIndex == index }.sorted { $0.agentIndex < $1.agentIndex }
            let active = list.contains { ThreadRelationships.isWorkActive($0.status) || $0.status == "idle" }
            return Phase(index: index, title: titles[index]!, members: list,
                         state: list.isEmpty ? "pending" : active ? "running" : "done",
                         settledCount: list.filter { Self.terminal.contains($0.status) }.count)
        }
        unphased = members.filter { $0.phaseIndex == nil }.sorted { $0.agentIndex < $1.agentIndex }
    }
}
