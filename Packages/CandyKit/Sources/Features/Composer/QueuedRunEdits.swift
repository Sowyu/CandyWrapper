import Foundation
import T3Protocol

/// T3 3814 packages/client-runtime/src/queuedRunEdit.ts:89-225.
/// Edits belong to threads, and a save keeps its claim even after cancellation.
public struct QueuedRunEdits {
    public struct Edit: Equatable {
        public let id = UUID()
        public let runId: RunId
        public let threadId: ThreadId
        public let originalText: String
        public var text: String
        /// The message named no model, so the edit shows the thread's pick and only an explicit pick is saved
        /// (useQueuedRunEdit.ts:306-312, 505-508 at 5258, #41814).
        public var followsThreadSelection = false
        /// The model the edit opened on; a different pick counts as an edit when the run leaves the queue.
        public var originalModel: ModelSelection?
        /// The edit's own model picks live under this key, apart from the thread's (`queuedRunEditDraftId`).
        public var pickerKey: String { "\(threadId.rawValue)#queued-edit:\(runId.rawValue)" }
    }
    private var edits: [ThreadId: Edit] = [:]
    private var saves: [ThreadId: UUID] = [:]
    public init() {}
    public func edit(_ thread: ThreadId) -> Edit? { edits[thread] }
    public func isSaving(_ thread: ThreadId) -> Bool { saves[thread] != nil }
    @discardableResult
    public mutating func begin(thread: ThreadId, run: RunId, text: String, followsThreadSelection: Bool = false,
                               originalModel: ModelSelection? = nil) -> Edit {
        let edit = Edit(runId: run, threadId: thread, originalText: text, text: text,
                        followsThreadSelection: followsThreadSelection, originalModel: originalModel)
        edits[thread] = edit
        return edit
    }
    public mutating func update(_ thread: ThreadId, text: String) { edits[thread]?.text = text }
    public mutating func end(_ thread: ThreadId) { edits[thread] = nil }
    public mutating func startSave(_ thread: ThreadId) -> Edit? {
        guard saves[thread] == nil, let edit = edits[thread] else { return nil }
        saves[thread] = edit.id
        return edit
    }
    @discardableResult
    public mutating func finishSave(_ edit: Edit, succeeded: Bool) -> Bool {
        guard saves[edit.threadId] == edit.id else { return false }
        saves[edit.threadId] = nil
        guard edits[edit.threadId]?.id == edit.id else { return false }
        if succeeded { end(edit.threadId) }
        return true
    }
    /// A missing projection is still loading. A save pauses exit recovery until its answer.
    public mutating func takeExited(_ thread: ThreadId, queuedRuns: Set<RunId>?) -> Edit? {
        guard saves[thread] == nil, let queuedRuns, let edit = edits[thread], !queuedRuns.contains(edit.runId) else { return nil }
        end(thread)
        return edit
    }
}
