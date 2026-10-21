import Foundation
import T3Protocol

// The thread relationship graph behind the thread details card's Lineage section, the subagent bar
// and merge back. Paths are relative to the pingdotgg/t3code checkout in ../CandyWrapper-research/t3code;
// RT is packages/client-runtime/src/state. Every id here is local to one environment: callers pass the
// environment's shells unscoped (`ThreadRelationships.unscoped`).

public enum ThreadRelationshipKind: String, Sendable { case parent, fork, subagent, transfer }

public struct ThreadRelationshipNode: Sendable, Equatable {
    public let threadId: ThreadId
    public let thread: ThreadShell?
    public let missing: Bool
}

public struct ThreadRelationshipEdge: Sendable, Hashable {
    public let sourceThreadId: ThreadId
    public let targetThreadId: ThreadId
    public let kind: ThreadRelationshipKind
    public let status: String?
}

public struct ThreadRelationshipGraph: Sendable {
    public let nodes: [ThreadId: ThreadRelationshipNode]
    public let edges: [ThreadRelationshipEdge]
}

public struct ThreadRelationshipRow: Sendable, Equatable {
    public let threadId: ThreadId
    public let fromThreadId: ThreadId
    public let depth: Int
    public let edge: ThreadRelationshipEdge
}

/// The fields of `OrchestrationV2Subagent` (orchestrationV2.ts:663-701) the Lineage rows read; the
/// projection keeps subagents as JSON.
public struct ProjectedSubagent: Sendable, Equatable {
    public let id: String
    public let childThreadId: ThreadId?
    public let origin: String
    public let driver: String
    public let providerInstanceId: String
    public let title: String
    public let model: String?
    public let status: String
    public let progress: String?
    public let result: String?
    public let startedAt: T3Timestamp?
    public let completedAt: T3Timestamp?

    public init(id: String, childThreadId: ThreadId?, origin: String, driver: String, providerInstanceId: String, title: String,
                model: String?, status: String, progress: String?, result: String?, startedAt: T3Timestamp?, completedAt: T3Timestamp?) {
        self.id = id; self.childThreadId = childThreadId; self.origin = origin; self.driver = driver
        self.providerInstanceId = providerInstanceId; self.title = title; self.model = model; self.status = status
        self.progress = progress; self.result = result; self.startedAt = startedAt; self.completedAt = completedAt
    }

    /// `projectedSubagentsToRuntime` (RT/subagentRuntime.ts:107-156): the title falls back to the prompt,
    /// 77 characters and "..." past 80.
    public init?(_ json: JSONValue) {
        guard let id = json["id"]?.stringValue, let status = json["status"]?.stringValue else { return nil }
        let prompt = json["prompt"]?.stringValue ?? ""
        let fallbackTitle: String = prompt.count > 80 ? String(prompt.prefix(77)) + "..." : prompt
        let child: ThreadId? = json["childThreadId"]?.stringValue.map { ThreadId($0) }
        let started: T3Timestamp? = json["startedAt"]?.stringValue.map { T3Timestamp($0) }
        let completed: T3Timestamp? = json["completedAt"]?.stringValue.map { T3Timestamp($0) }
        self.init(id: id, childThreadId: child, origin: json["origin"]?.stringValue ?? "provider_native",
                  driver: json["driver"]?.stringValue ?? "", providerInstanceId: json["providerInstanceId"]?.stringValue ?? "",
                  title: json["title"]?.stringValue ?? fallbackTitle, model: json["model"]?.stringValue, status: status,
                  progress: json["progress"]?.stringValue, result: json["result"]?.stringValue,
                  startedAt: started, completedAt: completed)
    }

    /// `liveSubagent` (ThreadRelationshipsControl.tsx:177-194): while the child thread has a live run, the
    /// row's timer and card follow that run, not the settled task.
    /// A supervisor still waiting on its worker keeps its own status (321b86b05d, ThreadRelationshipsControl.tsx:178-182).
    public func following(_ child: ThreadShell?) -> ProjectedSubagent {
        guard !ThreadRelationships.isWorkActive(status), let live = child?.activityRunStatus?.rawValue else { return self }
        let started: T3Timestamp? = if case .value(let t) = child?.activityRunStartedAt { t } else { nil }
        return ProjectedSubagent(id: id, childThreadId: childThreadId, origin: origin, driver: driver, providerInstanceId: providerInstanceId,
                                 title: title, model: model, status: live == "running" || live == "waiting" ? live : "pending",
                                 progress: nil, result: nil, startedAt: started, completedAt: nil)
    }
}

public enum ThreadRelationships {
    /// `parentThreadLink` (ChatView.tsx:2154-2175 in 2994): only a subagent names its parent, titled from the
    /// parent's shell or "Parent thread" while that shell is missing. Forks get no link.
    public static func parentLink(_ lineage: ThreadLineage?, threads: [ThreadShell]) -> (threadId: ThreadId, title: String)? {
        guard lineage?.relationshipToParent == .subagent, let parent = lineage?.parentThreadId else { return nil }
        return (parent, threads.first { $0.id == parent }?.title ?? "Parent thread")
    }

    /// The environment's shells with local ids, the way the projection names threads.
    public static func unscoped(_ shells: [ThreadShell], environmentId: String) -> [ThreadShell] {
        shells.compactMap { shell in
            guard shell.id.environmentId == environmentId else { return nil }
            var s = shell
            s.id = shell.id.localId
            s.projectId = ProjectId(EnvironmentScope.localId(of: shell.projectId.rawValue))
            s.lineage.parentThreadId = shell.lineage.parentThreadId?.localId
            s.lineage.rootThreadId = shell.lineage.rootThreadId.localId
            s.forkedFrom?.threadId = shell.forkedFrom?.threadId?.localId
            return s
        }
    }

    /// The shells the lineage can read: the thread, its parent, its children, the projection's subagent and transfer
    /// threads and its merge target. Only edges that touch the thread make rows (`immediate`), so
    /// the rest never change the result. Copying every shell of the environment ran on each shell and projection change,
    /// about 4 ms a time with 1,400 threads (docs/research/m10-load-2026-10-12.md).
    public static func related(_ all: [ThreadShell], to threadId: ThreadId, projection: ThreadProjection) -> [ThreadShell] {
        func parent(_ t: ThreadShell) -> ThreadId? { t.forkedFrom?.type == "run" ? t.forkedFrom?.threadId : t.lineage.parentThreadId }
        var local: Set<ThreadId> = [threadId.localId]
        if let me = all.first(where: { $0.id == threadId }), let p = parent(me) { local.insert(p.localId) }
        if let p = projection.thread.lineage?.parentThreadId { local.insert(p.localId) }
        for s in projection.subagents.compactMap(ProjectedSubagent.init) { if let c = s.childThreadId { local.insert(c.localId) } }
        for t in projection.contextTransfers {
            for key in ["sourceThreadId", "targetThreadId"] { if let id = t[key]?.stringValue { local.insert(ThreadId(id).localId) } }
        }
        if let target = ThreadRelationships.mergeBackTarget(projection) { local.insert(target.localId) }
        guard let env = threadId.environmentId else { return all }
        // Compare whole ids, without splitting each shell's id on every call.
        let scoped = Set(local.map { $0.scoped(to: env) }), localThread = threadId.localId
        return all.filter { s in
            if scoped.contains(s.id) { return true }
            guard let p = parent(s), p == threadId || p == localThread else { return false }
            return s.id.environmentId == env
        }
    }

    /// `resolveMergeBackTargetThreadId` (RT/threadRelationships.ts:35-42).
    public static func mergeBackTarget(_ projection: ThreadProjection?) -> ThreadId? {
        guard let thread = projection?.thread, thread.lineage?.relationshipToParent == .fork else { return nil }
        if thread.raw["forkedFrom"]?["type"]?.stringValue == "run", let id = thread.raw["forkedFrom"]?["threadId"]?.stringValue {
            return ThreadId(id)
        }
        return thread.lineage?.parentThreadId
    }

    /// `deriveThreadRelationshipGraph` (RT/threadRelationships.ts:48-117). `threads` runs from most to least
    /// authoritative (live shells before archived ones); the first copy of an id wins.
    public static func graph(threads: [ThreadShell], projection: ThreadProjection?) -> ThreadRelationshipGraph {
        var byId: [ThreadId: ThreadShell] = [:]
        var order: [ThreadShell] = []
        for t in threads where byId[t.id] == nil { byId[t.id] = t; order.append(t) }
        var nodes: [ThreadId: ThreadRelationshipNode] = [:]
        for t in order { nodes[t.id] = ThreadRelationshipNode(threadId: t.id, thread: t, missing: false) }
        var edges: [ThreadRelationshipEdge] = []
        var index: [String: Int] = [:]
        func add(_ e: ThreadRelationshipEdge) {
            for id in [e.sourceThreadId, e.targetThreadId] where nodes[id] == nil {
                nodes[id] = ThreadRelationshipNode(threadId: id, thread: nil, missing: true)
            }
            let key = "\(e.sourceThreadId.rawValue)\u{1f}\(e.targetThreadId.rawValue)\u{1f}\(e.kind.rawValue)"
            if let i = index[key] { edges[i] = e } else { index[key] = edges.count; edges.append(e) }
        }
        for t in order {
            let parent = t.forkedFrom?.type == "run" ? t.forkedFrom?.threadId : t.lineage.parentThreadId
            guard let parent else { continue }
            add(ThreadRelationshipEdge(sourceThreadId: parent, targetThreadId: t.id,
                                       kind: t.lineage.relationshipToParent == .subagent ? .subagent : .fork,
                                       status: (t.activityRunStatus ?? t.status).rawValue))
        }
        if let projection {
            let owner = projection.thread.id
            for s in projection.subagents.compactMap(ProjectedSubagent.init) {
                guard let child = s.childThreadId else { continue }
                // The record settles with the delegated task's first run; a live run on the child outranks it, and a
                // later run's status does too unless the agent is still working (deriveThreadRelationshipGraph,
                // RT/threadRelationships.ts:101-111).
                let shell = byId[child]
                let status = shell?.activityRunStatus?.rawValue
                    ?? (shell?.latestRunId != nil && !isWorkActive(s.status) ? shell!.status.rawValue : s.status)
                add(ThreadRelationshipEdge(sourceThreadId: owner, targetThreadId: child, kind: .subagent, status: status))
            }
            for transfer in projection.contextTransfers {
                guard let source = transfer["sourceThreadId"]?.stringValue, let target = transfer["targetThreadId"]?.stringValue,
                      source != target else { continue }
                add(ThreadRelationshipEdge(sourceThreadId: ThreadId(source), targetThreadId: ThreadId(target), kind: .transfer,
                                           status: transfer["status"]?.stringValue))
            }
        }
        return ThreadRelationshipGraph(nodes: nodes, edges: edges)
    }

    /// `immediateThreadRelationships` (RT/threadRelationships.ts:162-182).
    public static func immediate(_ graph: ThreadRelationshipGraph, _ threadId: ThreadId) -> [ThreadRelationshipRow] {
        var seen: Set<ThreadId> = []
        var rows: [ThreadRelationshipRow] = []
        for e in graph.edges {
            let related = e.sourceThreadId == threadId ? e.targetThreadId : e.targetThreadId == threadId ? e.sourceThreadId : nil
            guard let related, seen.insert(related).inserted else { continue }
            rows.append(ThreadRelationshipRow(threadId: related, fromThreadId: threadId, depth: 1, edge: e))
        }
        return rows
    }

    /// `isParentThreadRelationship` (:185-190): the edge reaches `current` from its parent or owning agent.
    public static func isParent(_ edge: ThreadRelationshipEdge, _ current: ThreadId) -> Bool {
        edge.kind != .transfer && edge.targetThreadId == current
    }

    /// `threadRelationshipRowStatus` (:193-202): an incoming parent row shows its own activity.
    public static func rowStatus(_ graph: ThreadRelationshipGraph, _ row: ThreadRelationshipRow) -> String? {
        if row.edge.kind == .transfer || row.threadId == row.edge.targetThreadId { return row.edge.status }
        let t = graph.nodes[row.threadId]?.thread
        return (t?.activityRunStatus ?? t?.status)?.rawValue
    }

    /// `orderWebThreadLineageRows` (:227-251): the parent first, then a distinct merge-back target, then
    /// newest created first; missing shells sink, ties break by id.
    public static func orderLineage(_ graph: ThreadRelationshipGraph, _ rows: [ThreadRelationshipRow],
                                    current: ThreadId, mergeTarget: ThreadId?) -> [ThreadRelationshipRow] {
        func pin(_ r: ThreadRelationshipRow) -> Int { isParent(r.edge, current) ? 0 : r.threadId == mergeTarget ? 1 : 2 }
        func created(_ r: ThreadRelationshipRow) -> Int64? { graph.nodes[r.threadId]?.thread?.createdAt.epochMs }
        return rows.sorted { l, r in
            if pin(l) != pin(r) { return pin(l) < pin(r) }
            let lc = created(l), rc = created(r)
            if lc != rc {
                guard let lc else { return false }
                guard let rc else { return true }
                return lc > rc
            }
            return l.threadId.rawValue < r.threadId.rawValue
        }
    }

    /// `threadRelationshipStatusLabel` (ThreadRelationshipIcon.tsx:6-43).
    public static func statusLabel(_ status: String?) -> String {
        switch status {
        case "preparing", "starting": "Starting"
        case "running", "in_progress": "Running"
        case "pending", "queued": "Queued"
        case "waiting", "blocked": "Waiting"
        case "completed": "Done"
        case "failed", "error": "Failed"
        case "cancelled", "interrupted": "Stopped"
        case "rolled_back": "Reverted"
        case "resolved_native": "Resolved (native)"
        case "resolved_portable": "Resolved (portable)"
        case "consumed": "Consumed"
        case "superseded": "Superseded"
        case "idle": "Idle"
        default: "Unknown"
        }
    }

    /// The badge dot's tone under a relationship icon (ThreadRelationshipIcon.tsx:71-85).
    public enum Dot: Sendable { case info, destructive, success, muted }
    public static func dot(_ status: String?) -> Dot {
        switch status {
        case "running", "in_progress", "pending", "waiting": .info
        case "failed", "error": .destructive
        case "completed": .success
        default: .muted
        }
    }

    /// `formatSubagentDisplayTitle` (RT/subagentDisplay.ts:47-54): drops "Subagent:" and turns a Codex task
    /// path `/root/.../task_name` into "Task Name".
    public static func subagentDisplayTitle(_ title: String) -> String {
        let display = title.replacing(/^(?i)Subagent:\s*/, with: "")
        guard let m = display.wholeMatch(of: /\/root\/(?:[^\/]+\/)*([^\/]+)\/?/) else { return display }
        let name = String(m.1).replacing(/[_\s]+/, with: " ").trimmingCharacters(in: .whitespaces)
        let titled = name.split(separator: " ", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? "" : $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        return titled.isEmpty ? display : titled
    }

    /// `isOrchestrationV2WorkActive` (orchestrationV2.ts:705-709).
    public static func isWorkActive(_ status: String) -> Bool { status == "pending" || status == "running" || status == "waiting" }

    /// `deriveSubagentElapsedMs` (packages/shared/src/orchestrationTiming.ts:4-21): live agents run to now,
    /// settled ones to `completedAt`; unknown timing is nil.
    public static func subagentElapsedMs(status: String, startedAt: T3Timestamp?, completedAt: T3Timestamp?, nowMs: Int64) -> Int64? {
        guard let start = startedAt?.epochMs else { return nil }
        let end = isWorkActive(status) ? nowMs : completedAt?.epochMs
        guard let end else { return nil }
        return max(0, end - start)
    }

    /// Milliseconds until the text of `elapsed` (or `compactElapsed`) for `elapsedMs` next changes, so a
    /// live label wakes the app when its text changes and not once a second regardless.
    public static func msUntilElapsedChanges(_ elapsedMs: Int64, compact: Bool) -> Int64 {
        let ms = max(0, elapsedMs), s = ms / 1000
        let unit: Int64 = compact
            ? (s < 60 ? 1_000 : s < 3_600 ? 60_000 : s < 36_000 ? 360_000 : 3_600_000)
            : (s < 3_600 ? 1_000 : 60_000)
        return unit - ms % unit
    }

    /// `formatCompactElapsedSeconds` (AgentElapsed.tsx:20-27): "45s", "12m", "1.5h", "14h", rounded down.
    public static func compactElapsed(seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        if s < 60 { return "\(s)s" }
        let m = s / 60
        if m < 60 { return "\(m)m" }
        if m >= 600 { return "\(m / 60)h" }
        let tenths = Double(m / 6) / 10
        return tenths == tenths.rounded() ? "\(Int(tenths))h" : "\(tenths)h"
    }

    /// `formatElapsedSeconds` (AgentElapsed.tsx:6-17): "45s", "12m 05s", "1h 05m".
    public static func elapsed(seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        let m = s / 60
        if m == 0 { return "\(s)s" }
        let h = m / 60
        if h == 0 { return "\(m)m \(String(format: "%02d", s % 60))s" }
        return "\(h)h \(String(format: "%02d", m % 60))m"
    }

    // MARK: - Workflows (RT/threadWorkflows.ts)

    private static let mergeBackStatuses: Set<String> = ["waiting", "completed"]
    private static let mergeBackBlocking: Set<String> = ["preparing", "starting", "running"]
    private static let activeRunStatuses: Set<String> = ["preparing", "starting", "running", "waiting"]

    /// `resolveLatestMergeBackRun` (:48-64): the newest provider-finished run, unless a newer one is live.
    public static func latestMergeBackRun(_ projection: ThreadProjection) -> Run? {
        let latest = projection.runs.reduce(nil as Run?) { latest, run in
            mergeBackStatuses.contains(run.status.rawValue) && (latest == nil || run.ordinal > latest!.ordinal) ? run : latest
        }
        guard let latest else { return nil }
        let newerActive = projection.runs.contains { $0.ordinal > latest.ordinal && mergeBackBlocking.contains($0.status.rawValue) }
        return newerActive ? nil : latest
    }

    /// `resolveActiveThreadRun` (:39-41).
    public static func activeRun(_ projection: ThreadProjection) -> Run? {
        projection.runs.last { activeRunStatuses.contains($0.status.rawValue) }
    }

    /// `resolveThreadProviderSession` (:66-88): the active run's provider thread's session, else the thread's
    /// attached one, else the newest session neither stopped nor in error.
    public static func providerSession(_ projection: ThreadProjection) -> JSONValue? {
        let providerThreadId = activeRun(projection)?.providerThreadId ?? projection.thread.activeProviderThreadId
        let active = providerThreadId.flatMap { id in projection.providerThreads.first { $0["id"]?.stringValue == id } }
        let attached = active ?? projection.providerThreads.first {
            $0["appThreadId"]?.stringValue == projection.thread.id.rawValue && $0["providerSessionId"]?.stringValue != nil
        }
        if let sessionId = attached?["providerSessionId"]?.stringValue {
            return projection.providerSessions.first { $0["id"]?.stringValue == sessionId }
        }
        return projection.providerSessions.last {
            let s = $0["status"]?.stringValue
            return s != "stopped" && s != "error"
        }
    }

    /// `canDetachThreadProviderSession` (:187-190).
    public static func canDetachSession(_ projection: ThreadProjection) -> Bool {
        guard let s = providerSession(projection)?["status"]?.stringValue else { return false }
        return s != "stopped" && s != "error"
    }

    /// `canForkProjectedAssistantItem` (:165-185): a completed assistant message in a run, on a provider
    /// that forks natively or hands off the full thread; with no capability evidence, allowed.
    public static func canFork(_ item: ProjectedTurnItem, capabilities: JSONValue?) -> Bool {
        let i = item.item
        guard i.type == .assistantMessage, i.runId != nil, i.status == .completed else { return false }
        guard let c = capabilities else { return true }
        let native = c["threads"]?["canForkThread"]?.boolValue == true && c["threads"]?["canForkFromTurn"]?.boolValue == true
            && c["identity"]?["nativeThreadIds"]?.stringValue == "strong"
        return native || c["context"]?["supportsFullThreadHandoff"]?.boolValue == true
    }

    // MARK: - Lineage section

    /// The rows `ThreadRelationshipsPanel` draws (ThreadRelationshipsControl.tsx:196-285): related rows
    /// (parents, forks, transfers), then active subagents, then settled ones under "Previous agents".
    public struct Lineage: Sendable, Equatable {
        public struct Row: Sendable, Equatable {
            public let threadId: ThreadId
            public let edge: ThreadRelationshipEdge
            public let status: String?
            public let isParent: Bool
            public let isSubagent: Bool
            public let isMergeTarget: Bool
            public let missing: Bool
            public let title: String
            /// The subagent behind a child row (never a parent row), following the child's live run.
            public let agent: ProjectedSubagent?
            public let child: ThreadShell?
            /// "Subagent", "Parent agent", "Fork", "Parent thread" or "Context transfer".
            public let relationship: String
            /// A workflow coordinator's phases and members (2994 servers), which the row unfolds into.
            public var workflow: SubagentWorkflowGroup? = nil
            public var failed: Bool { status == "failed" || status == "error" }
            /// Stop shows on hover for an app-owned task that started and still works.
            public var canStop: Bool {
                guard let agent else { return false }
                return agent.origin == "app_owned" && agent.startedAt != nil && ["pending", "running", "waiting"].contains(agent.status)
            }
        }
        public var related: [Row] = []
        public var active: [Row] = []
        public var previous: [Row] = []
        public var runningCount = 0
        public var mergeTarget: ThreadId?
        public var mergeRunId: RunId?
        public var canDetach = false
        /// Workflow members' threads that exist here, so their rows can open them.
        public var availableMembers: Set<ThreadId> = []
        public var isEmpty: Bool { related.isEmpty && active.isEmpty && previous.isEmpty && runningCount == 0 }
        /// "Lineage" or "Lineage · N running".
        public var title: String { runningCount > 0 ? "Lineage · \(runningCount) running" : "Lineage" }
        public init() {}

        #if DEBUG
        /// `count` settled subagent rows under "Previous agents", for checking a long Lineage on screen without
        /// real turns (`CANDY_FAKE_LINEAGE=<count>` in a Debug app).
        public static func syntheticPrevious(_ count: Int, current: ThreadId) -> [Row] {
            (1...max(1, count)).map { i in
                let id = ThreadId("synthetic-agent-\(i)")
                let edge = ThreadRelationshipEdge(sourceThreadId: current, targetThreadId: id, kind: .subagent, status: "completed")
                return Row(threadId: id, edge: edge, status: "idle", isParent: false, isSubagent: true, isMergeTarget: false,
                           missing: false, title: "Synthetic agent \(i): check the details card scrolls", agent: nil, child: nil,
                           relationship: "Subagent")
            }
        }
        #endif
    }

    /// `relationshipLabel` (:156-162).
    static func relationshipLabel(_ edge: ThreadRelationshipEdge, _ current: ThreadId) -> String {
        switch edge.kind {
        case .transfer: "Context transfer"
        case .subagent: edge.sourceThreadId == current ? "Subagent" : "Parent agent"
        default: edge.sourceThreadId == current ? "Fork" : "Parent thread"
        }
    }

    private static let settledStatuses: Set<String> = ["completed", "failed", "error", "cancelled", "interrupted", "idle"]

    public static func lineage(threadId: ThreadId, threads: [ThreadShell], projection: ThreadProjection?) -> Lineage {
        let g = graph(threads: threads, projection: projection)
        let mergeTarget = mergeBackTarget(projection)
        let agents = (projection?.subagents ?? []).compactMap(ProjectedSubagent.init)
        var byChild: [ThreadId: ProjectedSubagent] = [:]
        for a in agents { if let c = a.childThreadId { byChild[c] = a } }
        let workflows = Dictionary((projection?.subagents ?? []).compactMap(SubagentWorkflowGroup.init(coordinator:)).map { ($0.coordinatorId, $0) },
                                   uniquingKeysWith: { a, _ in a })
        var out = Lineage()
        out.mergeTarget = mergeTarget
        out.mergeRunId = projection.flatMap(latestMergeBackRun)?.id
        out.canDetach = projection.map(canDetachSession) ?? false
        for r in orderLineage(g, immediate(g, threadId), current: threadId, mergeTarget: mergeTarget) {
            let node = g.nodes[r.threadId]
            let isSubagent = r.edge.kind == .subagent
            let parent = isParent(r.edge, threadId)
            let projected = isSubagent && !parent ? byChild[r.threadId] : nil
            // A workflow row takes the coordinator's status and name, and its agent does not follow the child's run
            // (ThreadRelationshipsControl.tsx:296-306, 457-481 in 2994).
            let workflow = projected.flatMap { workflows[$0.id] }
            var r = r
            if let workflow {
                r = ThreadRelationshipRow(threadId: r.threadId, fromThreadId: r.fromThreadId, depth: r.depth,
                                          edge: ThreadRelationshipEdge(sourceThreadId: r.edge.sourceThreadId, targetThreadId: r.edge.targetThreadId,
                                                                       kind: r.edge.kind, status: workflow.status))
            }
            let agent = workflow != nil ? projected : projected?.following(node?.thread)
            let raw = workflow?.name ?? node?.thread?.title ?? agent?.title ?? r.threadId.rawValue
            var row = Lineage.Row(threadId: r.threadId, edge: r.edge, status: rowStatus(g, r), isParent: parent, isSubagent: isSubagent,
                                  isMergeTarget: r.threadId == mergeTarget, missing: node?.missing ?? true,
                                  title: isSubagent ? subagentDisplayTitle(raw) : raw, agent: agent, child: node?.thread,
                                  relationship: relationshipLabel(r.edge, threadId))
            row.workflow = workflow
            for m in (workflow?.phases.flatMap(\.members) ?? []) + (workflow?.unphased ?? []) {
                if let c = m.childThreadId, g.nodes[c]?.missing == false { out.availableMembers.insert(c) }
            }
            if !isSubagent || parent { out.related.append(row) }
            else if settledStatuses.contains(r.edge.status ?? "") { out.previous.append(row) }
            else { out.active.append(row) }
        }
        // Subagents without a child thread yet have no row; they still count.
        out.runningCount = agents.filter { $0.childThreadId == nil && $0.status == "running" }.count
            + out.active.filter { $0.edge.status == "running" }.count
        return out
    }

    // MARK: - Provider subagent bar (RT/threadExecution.ts)

    /// `ProviderSubagentStatus` (:123-127): the runless root turn of a provider-native subagent thread.
    public struct SubagentStatus: Sendable, Equatable {
        public let status: String
        public let startedAt: T3Timestamp?
        public let completedAt: T3Timestamp?
        public init(status: String, startedAt: T3Timestamp?, completedAt: T3Timestamp?) {
            self.status = status; self.startedAt = startedAt; self.completedAt = completedAt
        }
    }

    /// `deriveProviderSubagentStatus` (:134-147): nil until the root turn arrives, and for other threads.
    public static func providerSubagentStatus(_ projection: ThreadProjection) -> SubagentStatus? {
        guard projection.thread.isProviderNativeSubagent,
              let node = projection.nodes.last(where: { $0.kind == "root_turn" && $0.runId == nil }) else { return nil }
        return SubagentStatus(status: node.status, startedAt: node.startedAt, completedAt: node.completedAt)
    }

    /// `SUBAGENT_STATUS_LABELS` (:186-196).
    static func subagentStatusLabel(_ status: String) -> String {
        switch status {
        case "idle": "Idle"
        case "pending", "running": "Working"
        case "waiting": "Waiting"
        case "completed": "Completed"
        case "interrupted": "Interrupted"
        case "failed": "Failed"
        case "cancelled", "rolled_back": "Cancelled"
        default: status
        }
    }

    /// `formatProviderSubagentStatus` (:204-222): "Working 12s", "Completed in 34s", or just the status.
    public static func formatSubagentStatus(_ status: SubagentStatus?, nowMs: Int64) -> String {
        guard let status else { return "Starting" }
        let label = subagentStatusLabel(status.status)
        let live = isWorkActive(status.status)
        if !live && status.status != "completed" { return label }
        guard let start = status.startedAt?.epochMs, let end = live ? nowMs : status.completedAt?.epochMs else { return label }
        // Whole seconds: a ticking label must not flicker through tenths.
        let elapsed = formatDuration(max(1_000, Double((end - start) / 1_000 * 1_000)))
        return live ? "\(label) \(elapsed)" : "\(label) in \(elapsed)"
    }

    /// `formatDuration` (packages/shared/src/orchestrationTiming.ts:36-53).
    public static func formatDuration(_ ms: Double) -> String {
        guard ms.isFinite, ms >= 0 else { return "0ms" }
        if ms < 1_000 { return "\(max(1, Int(ms.rounded())))ms" }
        if ms < 10_000 {
            let tenths = (ms / 100).rounded() / 10
            return tenths >= 10 ? "10s" : String(format: "%.1fs", tenths)
        }
        let total = Int((ms / 1_000).rounded())
        // The unit follows the rounded seconds, so 59.5 seconds never reads "60s" (bd93830550, :41-43).
        if total < 60 { return "\(total)s" }
        let h = total / 3_600, m = (total % 3_600) / 60, s = total % 60
        return [h > 0 ? "\(h)h" : nil, m > 0 ? "\(m)m" : nil, s > 0 ? "\(s)s" : nil].compactMap { $0 }.joined(separator: " ")
    }

    // MARK: Model labels (packages/shared/src/model.ts, RT/threadExecution.ts)

    /// `resolveSelectableModel` (model.ts:421-460) by slug, name or alias, case-insensitively for the last two.
    // ponytail: no dated-id normalization (`claude-haiku-4-5-20251001`); add `normalizeModelSlug` if bars show raw slugs
    public static func resolveModel(_ models: [ServerProviderModel], _ value: String) -> ServerProviderModel? {
        let t = value.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        return models.first { $0.slug == t } ?? models.first { $0.name.lowercased() == t.lowercased() }
            ?? models.first { $0.aliases?.contains { $0.lowercased() == t.lowercased() } == true }
    }

    /// `formatModelSlugName` (model.ts:315-329): `claude-haiku-4-5` reads "Claude Haiku 4.5"; other slugs stay.
    // ponytail: `gpt-*` names stay raw; port `formatCodexModelName` with Codex subagents
    public static func modelSlugName(_ slug: String) -> String {
        let cut = slug.lastIndex(of: "/").map { slug.index(after: $0) } ?? slug.startIndex
        let prefix = String(slug[..<cut]), name = String(slug[cut...])
        guard name.contains(/^(?i)(claude-(opus|sonnet|haiku|fable)|gemini|grok|composer)-\d/) else { return slug }
        let dotted = name.replacing(/^(?<m>(?i)claude-[a-z]+-\d+)-(?<n>\d{1,2})(?=-|\[|$)/) { "\($0.m).\($0.n)" }
        return prefix + dotted.split(separator: "-", omittingEmptySubsequences: false)
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// `formatModelSelectionEffort` (RT/threadExecution.ts:162-186): the first reasoning select the selection states,
    /// or the provider reported for the same instance and model. A catalog default or `currentValue` no longer
    /// counts (53ef45feac, shared/src/model.ts:214-287).
    public static func effortLabel(_ selection: ModelSelection, model: ServerProviderModel?, reported: ModelSelection? = nil) -> String? {
        guard let model else { return nil }
        func values(_ options: JSONValue?) -> [String: ProviderOptionValue] {
            let list = (try? options?.decode(as: [ProviderOptionSelection].self)) ?? nil
            return Dictionary((list ?? []).map { ($0.id, $0.value) }, uniquingKeysWith: { first, _ in first })
        }
        let stated = values(selection.options)
        let sameRun = reported.map { $0.instanceId == selection.instanceId && $0.model == selection.model } ?? false
        let reportedValues = sameRun ? values(reported?.options) : [:]
        for id in ModelTraits.reasoningEffortIds {
            guard let d = model.optionDescriptors.first(where: { $0.id == id }), d.type == .select else { continue }
            let reportedValue = stated[id] == nil ? reportedValues[id] : nil
            let value = stated[id] ?? reportedValue
            if value == nil && id != "variant" { continue }
            if case .bool? = value { continue }
            // `getProviderOptionCurrentValue` with the stated value as `currentValue`.
            let current: String? = if let r = reportedValue?.string { r }
                else if id == "variant" && stated[id] == nil { nil }
                else if let v = value?.string, !v.isEmpty { v }
                else { d.options.first { $0.isDefault == true }?.id }
            let label = d.options.first { $0.id == current }?.label
                ?? (reportedValue?.string == "default" ? "Default" : id == "variant" ? "Unknown" : nil)
            if let label { return label }
        }
        return nil
    }

    /// `deriveReportedModelSelection` (RT/threadExecution.ts:143-152): what the active provider thread reports running.
    public static func reportedSelection(_ projection: ThreadProjection, instanceId: ProviderInstanceId?) -> ModelSelection? {
        guard let active = projection.thread.activeProviderThreadId, let instanceId else { return nil }
        let thread = projection.providerThreads.first {
            $0["id"]?.stringValue == active && $0["providerInstanceId"]?.stringValue == instanceId.rawValue
        }
        return (try? thread?["nativeMetadata"]?["modelSelection"]?.decode(as: ModelSelection.self)) ?? nil
    }
}
