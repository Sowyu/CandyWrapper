import T3Protocol

/// `childThreadInputsAtom` (packages/client-runtime/src/state/threadShell.ts:282-325): the thread's subagents, at any
/// depth, that wait on an approval or a question while their run still lives. Provider-native subagents ask in their
/// parent.
public enum ChildThreadInputs {
    public static func pending(for threadId: ThreadId, in threads: [ThreadShell]) -> [ThreadShell] {
        var children: [ThreadId: [ThreadShell]] = [:]
        for thread in threads where thread.lineage.relationshipToParent == .subagent {
            if let parent = thread.lineage.parentThreadId { children[parent, default: []].append(thread) }
        }
        var seen: Set<ThreadId> = [threadId], queue = [threadId], result: [ThreadShell] = []
        var index = 0
        while index < queue.count {
            for child in children[queue[index]] ?? [] where seen.insert(child.id).inserted {
                queue.append(child.id)
                if PendingSubagentRequests.request(child) != nil {
                    result.append(child)
                }
            }
            index += 1
        }
        return result
    }

    /// `childThreadInputsTitle` (threadShell.ts:86-94).
    public static func title(_ children: [ThreadShell]) -> String {
        let approvals = children.filter(isApproval).count
        let need = approvals == 0 ? "input" : approvals == children.count ? "approval" : "you"
        return children.count == 1 ? "Subagent needs \(need)" : "\(children.count) subagents need \(need)"
    }

    /// The child's own `hasPendingApprovals` (models.ts:264-266).
    public static func isApproval(_ child: ThreadShell) -> Bool {
        guard let kind = child.pendingRuntimeRequest?.kind else { return false }
        return kind != .userInput && kind != .authRefresh
    }

    /// `isChildRunLive` (threadShell.ts:33-45, T3 3105 109aaae6c): an async question outlives the subagent's run, but
    /// once that run ends the parent no longer waits on it. Older servers send no activity run; their latest run's
    /// status stands in.
    static func childRunLive(_ thread: ThreadShell) -> Bool {
        if case .absent = thread.activityRunStartedAt {
            return [.preparing, .starting, .running, .waiting].contains(thread.status)
        }
        return thread.activityRunStatus != nil
    }
}

/// What a subagent waits on the user for (`PendingSubagentRequest`, models.ts:213).
public enum PendingSubagentRequest: String, Sendable, Equatable {
    case approval, userInput = "user_input"
}

public enum PendingSubagentRequests {
    /// `subagentRequest` (threadShell.ts:48-62): what a subagent's live run waits on the user for. Provider-native
    /// subagents ask on their parent, so they are skipped.
    static func request(_ thread: ThreadShell) -> PendingSubagentRequest? {
        guard let kind = thread.pendingRuntimeRequest?.kind, kind != .authRefresh,
              thread.lineage.relationshipToParent == .subagent, thread.creationSource != "provider",
              ChildThreadInputs.childRunLive(thread) else { return nil }
        return kind == .userInput ? .userInput : .approval
    }

    /// `pendingSubagentRequestsByThread` (threadShell.ts:64-89): the threads above a subagent that waits on the user,
    /// by what it waits on. Every thread up to the visible one carries it, because subagent rows are hidden. An
    /// approval outranks a question.
    public static func byThread(_ threads: [ThreadShell]) -> [ThreadId: PendingSubagentRequest] {
        var requests: [ThreadId: PendingSubagentRequest] = [:]
        var byId: [ThreadId: ThreadShell]?
        for child in threads {
            guard let request = request(child) else { continue }
            if byId == nil { byId = Dictionary(threads.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }) }
            var seen: Set<ThreadId> = [child.id]
            var current: ThreadShell? = child
            while let thread = current, thread.lineage.relationshipToParent == .subagent {
                guard let parentId = thread.lineage.parentThreadId, seen.insert(parentId).inserted else { break }
                if requests[parentId] != .approval { requests[parentId] = request }
                current = byId?[parentId]
            }
        }
        return requests
    }
}
