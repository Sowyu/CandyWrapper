import T3Protocol

/// `childThreadInputsAtom` (packages/client-runtime/src/state/threadShell.ts:156-197): the thread's subagents, at any
/// depth, that wait on a question while their run still lives. Provider-native subagents ask in their parent.
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
                if child.pendingRuntimeRequest?.kind == .userInput, childRunLive(child), child.creationSource != "provider" {
                    result.append(child)
                }
            }
            index += 1
        }
        return result
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
