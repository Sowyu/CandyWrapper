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
    }
    private var edits: [ThreadId: Edit] = [:]
    private var saves: [ThreadId: UUID] = [:]
    public init() {}
    public func edit(_ thread: ThreadId) -> Edit? { edits[thread] }
    public func isSaving(_ thread: ThreadId) -> Bool { saves[thread] != nil }
    @discardableResult
    public mutating func begin(thread: ThreadId, run: RunId, text: String) -> Edit {
        let edit = Edit(runId: run, threadId: thread, originalText: text, text: text)
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
