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
        /// The reply the message's text pointed at, shown above the composer instead of as a chip while it is edited
        /// (useQueuedRunEdit.ts:296-321 at 5258). `reply` is what the edit now replies to; Cancel reply clears it.
        public var originalReply: JSONValue?
        public var reply: JSONValue?
        /// Cancel reply or a different reply counts as an edit (`originalReplyTo`, queuedMessageEdit.ts:132 at 5258).
        public var replyChanged: Bool { reply?["contextId"] != originalReply?["contextId"] }
        /// The edit's own model picks and the attachments it adds live under this key, apart from the thread's
        /// (`queuedRunEditDraftId`).
        public var pickerKey: String { "\(threadId.rawValue)#queued-edit:\(runId.rawValue)" }
        /// The message's attachments as it was queued, and the ones the edit keeps. Removals stay local until a save
        /// (`originalAttachments`, `existingAttachments`, useQueuedRunEdit.ts:84-93 at 5258).
        public var originalAttachments: [JSONValue] = []
        public var existingAttachments: [JSONValue] = []
        /// The message's context records, so a save keeps the records of the attachments it keeps.
        public var messageRecords: [JSONValue] = []
        /// Each attachment's chip ids that the original text references (`attachmentContextIds`, useQueuedRunEdit.ts:243-249).
        public var attachmentContextIds: [String: [String]] = [:]
        public var removedAttachments: [JSONValue] {
            let kept = Set(existingAttachments.compactMap { $0["id"]?.stringValue })
            return originalAttachments.filter { !kept.contains($0["id"]?.stringValue ?? "") }
        }
        /// The edit has bound chips to reconcile against the text, so the text-change path parses only then.
        public var hasBoundChips: Bool { !attachmentContextIds.isEmpty }
    }
    private var edits: [ThreadId: Edit] = [:]
    private var saves: [ThreadId: UUID] = [:]
    public init() {}
    public func edit(_ thread: ThreadId) -> Edit? { edits[thread] }
    public func isSaving(_ thread: ThreadId) -> Bool { saves[thread] != nil }
    @discardableResult
    public mutating func begin(thread: ThreadId, run: RunId, text: String, followsThreadSelection: Bool = false,
                               originalModel: ModelSelection? = nil, reply: JSONValue? = nil) -> Edit {
        let edit = Edit(runId: run, threadId: thread, originalText: text, text: text,
                        followsThreadSelection: followsThreadSelection, originalModel: originalModel, originalReply: reply, reply: reply)
        edits[thread] = edit
        return edit
    }
    public mutating func update(_ thread: ThreadId, text: String) { edits[thread]?.text = text }

    /// Binds the queued message's attachments to the edit (`beginEdit`, useQueuedRunEdit.ts:294-345 at 5258).
    public mutating func setAttachments(_ thread: ThreadId, _ attachments: [JSONValue], records: [JSONValue]) {
        guard var edit = edits[thread] else { return }
        edit.originalAttachments = attachments
        edit.existingAttachments = attachments
        edit.messageRecords = records
        let referenced = Set(ComposerContext.referencedIds(edit.originalText))
        var bound: [String: [String]] = [:]
        for a in attachments {
            guard let id = a["id"]?.stringValue, let type = a["type"]?.stringValue else { continue }
            let ids = Self.contextIds(records: records, attachmentId: id, type: type).filter(referenced.contains)
            if !ids.isEmpty { bound[id] = ids }
        }
        edit.attachmentContextIds = bound
        edits[thread] = edit
    }

    /// `attachmentContextIdsForRecord` (queuedMessageEdit.ts:43-55 at 5258).
    public static func contextIds(records: [JSONValue], attachmentId: String, type: String) -> [String] {
        records.compactMap { r in
            r["kind"]?.stringValue == type && r["attachmentId"]?.stringValue == attachmentId ? r["contextId"]?.stringValue : nil
        }
    }

    /// `removeEditingAttachment` (useQueuedRunEdit.ts:390-410): drops it from the kept list and returns the chip ids
    /// the prompt must lose with it.
    @discardableResult
    public mutating func removeAttachment(_ thread: ThreadId, id: String) -> [String] {
        guard var edit = edits[thread], let removed = edit.existingAttachments.first(where: { $0["id"]?.stringValue == id }) else { return [] }
        edit.existingAttachments.removeAll { $0["id"]?.stringValue == id }
        edits[thread] = edit
        return Self.contextIds(records: edit.messageRecords, attachmentId: id, type: removed["type"]?.stringValue ?? "")
    }

    /// `restoreEditingAttachment` (useQueuedRunEdit.ts:411-423): back in its original position.
    public mutating func restoreAttachment(_ thread: ThreadId, id: String) {
        guard var edit = edits[thread] else { return }
        let kept = Set(edit.existingAttachments.compactMap { $0["id"]?.stringValue } + [id])
        edit.existingAttachments = edit.originalAttachments.filter { kept.contains($0["id"]?.stringValue ?? "") }
        edits[thread] = edit
    }

    /// `reconcileAttachmentContextReferences` for queued attachments (composerContextUndo.ts:107-123 at 5258): a file
    /// whose last chip left the text leaves the message, an image outlives its chip, and a removed attachment whose
    /// chip comes back (undo) returns. True when the kept list changed.
    @discardableResult
    public mutating func reconcile(_ thread: ThreadId, referenced: Set<String>) -> Bool {
        guard let edit = edits[thread], edit.hasBoundChips else { return false }
        let before = edit.existingAttachments.compactMap { $0["id"]?.stringValue }
        for a in edit.existingAttachments where a["type"]?.stringValue == "file" {
            guard let id = a["id"]?.stringValue, let ids = edit.attachmentContextIds[id], !ids.contains(where: referenced.contains) else { continue }
            removeAttachment(thread, id: id)
        }
        for a in edit.removedAttachments {
            guard let id = a["id"]?.stringValue, edit.attachmentContextIds[id]?.contains(where: referenced.contains) == true else { continue }
            restoreAttachment(thread, id: id)
        }
        return edits[thread]?.existingAttachments.compactMap { $0["id"]?.stringValue } != before
    }

    /// What `queued-run.edit` carries for the attachments (`submitQueuedRunEdit`, useQueuedRunEdit.ts:113-200 at 5258):
    /// the kept attachments, then the new ones, which replace the message's on the server, and the context records
    /// of the prompt's chips plus every kept or new attachment's record. Nil while a new upload is not ready, so a
    /// save never drops an attachment the user added.
    public static func savePayload(_ edit: Edit, staged: [ComposerAttachment], promptRecords: [JSONValue])
        -> (attachments: [JSONValue], records: [JSONValue])? {
        let added = staged.compactMap(\.chatAttachment)
        guard added.count == staged.count else { return nil }
        let kept = edit.existingAttachments.map(wireAttachment)
        let keptIds = Set(kept.compactMap { $0["id"]?.stringValue })
        let originalIds = Set(edit.originalAttachments.compactMap { $0["id"]?.stringValue })
        // A record bound to an attachment the edit removed goes with it.
        let isKept = { (r: JSONValue) in r["attachmentId"]?.stringValue.map { !originalIds.contains($0) || keptIds.contains($0) } ?? true }
        let keptRecords = edit.messageRecords.filter { r in
            guard let id = r["attachmentId"]?.stringValue, keptIds.contains(id) else { return false }
            return r["kind"]?.stringValue == "image" || r["kind"]?.stringValue == "file"
        }
        var seen = Set<String>(), records: [JSONValue] = []
        for r in promptRecords.filter(isKept) + keptRecords + staged.compactMap(\.contextRecord) {
            guard let id = r["contextId"]?.stringValue, seen.insert(id).inserted else { continue }
            records.append(r)
        }
        return (kept + added, records)
    }

    /// `ChatAttachment` as the command schema takes it (chatAttachment.ts:148-206 at 5258): the projection's
    /// display-only fields, like `downloadable` or `htmlRender`, stay behind.
    public static func wireAttachment(_ a: JSONValue) -> JSONValue {
        guard case .object(let fields) = a else { return a }
        return .object(fields.filter { ["type", "id", "name", "mimeType", "sizeBytes", "source"].contains($0.key) })
    }
    public mutating func cancelReply(_ thread: ThreadId) { edits[thread]?.reply = nil }
    public mutating func end(_ thread: ThreadId) { edits[thread] = nil }
    /// The claimed edit is still the open one: a cancel or a newer edit while its uploads ran means the save sends nothing.
    public func isOpen(_ claim: Edit) -> Bool { edits[claim.threadId]?.id == claim.id }
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
