import Foundation
import Testing
import T3Protocol
@testable import Features

/// Attachments in queued edits (useQueuedRunEdit.ts and queuedMessageEdit.ts at 5258, #40945).
struct QueuedEditAttachmentsTests {
    static let thread = ThreadId("env:t"), run = RunId("r")
    static let image: JSONValue = .object(["type": .string("image"), "id": .string("img-1"), "name": .string("shot.png"),
                                           "mimeType": .string("image/png"), "sizeBytes": .number(10), "downloadable": .bool(true)])
    static let file: JSONValue = .object(["type": .string("file"), "id": .string("file-1"), "name": .string("notes.txt"),
                                          "mimeType": .string("text/plain"), "sizeBytes": .number(4), "htmlRender": .bool(false)])
    static func record(_ kind: String, _ attachmentId: String, _ contextId: String) -> JSONValue {
        .object(["version": .number(1), "kind": .string(kind), "contextId": .string(contextId), "label": .string("x"),
                 "attachmentId": .string(attachmentId)])
    }
    static let imageChip = ComposerContext.reference(.init(kind: "image", contextId: "image_a", label: "shot.png"))
    static let fileChip = ComposerContext.reference(.init(kind: "file", contextId: "file_b", label: "notes.txt"))
    static let records = [record("image", "img-1", "image_a"), record("file", "file-1", "file_b")]

    static func editing(text: String) -> QueuedRunEdits {
        var edits = QueuedRunEdits()
        edits.begin(thread: thread, run: run, text: text)
        edits.setAttachments(thread, [image, file], records: records)
        return edits
    }

    @Test func anEditOpensWithTheMessagesAttachmentsAndBindsOnlyReferencedChips() throws {
        let edits = Self.editing(text: "look \(Self.imageChip)")
        let edit = try #require(edits.edit(Self.thread))
        #expect(edit.existingAttachments == [Self.image, Self.file])
        #expect(edit.removedAttachments.isEmpty)
        #expect(edit.attachmentContextIds == ["img-1": ["image_a"]])
    }

    @Test func removingAnAttachmentReturnsItsChipsAndRestoreKeepsTheOriginalOrder() throws {
        var edits = Self.editing(text: "look \(Self.imageChip)")
        let chips = edits.removeAttachment(Self.thread, id: "img-1")
        #expect(chips == ["image_a"])
        #expect(edits.edit(Self.thread)?.existingAttachments == [Self.file])
        #expect(edits.edit(Self.thread)?.removedAttachments == [Self.image])
        edits.restoreAttachment(Self.thread, id: "img-1")
        #expect(edits.edit(Self.thread)?.existingAttachments == [Self.image, Self.file])
    }

    @Test func deletingAFilesLastChipRemovesItButAnImageOutlivesItsChip() throws {
        var edits = Self.editing(text: "\(Self.imageChip) and \(Self.fileChip)")
        let r1 = edits.reconcile(Self.thread, referenced: ["image_a", "file_b"])
        #expect(!r1)
        let r2 = edits.reconcile(Self.thread, referenced: ["file_b"])
        #expect(!r2)
        #expect(edits.edit(Self.thread)?.existingAttachments.count == 2)
        let r3 = edits.reconcile(Self.thread, referenced: [])
        #expect(r3)
        #expect(edits.edit(Self.thread)?.existingAttachments == [Self.image])
        // Undo puts the chip back, and the file with it.
        let r4 = edits.reconcile(Self.thread, referenced: ["file_b"])
        #expect(r4)
        #expect(edits.edit(Self.thread)?.existingAttachments == [Self.image, Self.file])
    }

    @Test func aSaveSendsTheKeptAttachmentsWithoutDisplayFieldsAndDropsRemovedRecords() throws {
        var edits = Self.editing(text: "look \(Self.imageChip)")
        edits.removeAttachment(Self.thread, id: "file-1")
        let edit = try #require(edits.edit(Self.thread))
        let payload = try #require(QueuedRunEdits.savePayload(edit, staged: [], promptRecords: [Self.records[0]]))
        #expect(payload.attachments == [.object(["type": .string("image"), "id": .string("img-1"), "name": .string("shot.png"),
                                                 "mimeType": .string("image/png"), "sizeBytes": .number(10)])])
        #expect(payload.records.compactMap { $0["contextId"]?.stringValue } == ["image_a"])
        // A prompt record bound to the removed attachment goes too.
        let stale = try #require(QueuedRunEdits.savePayload(edit, staged: [], promptRecords: [Self.records[1]]))
        #expect(stale.records.compactMap { $0["contextId"]?.stringValue } == ["image_a"])
    }

    @Test func aFailedSaveKeepsTheEditAsItWas() throws {
        var edits = Self.editing(text: "hi")
        edits.removeAttachment(Self.thread, id: "img-1")
        let started = edits.startSave(Self.thread)
        let claim = try #require(started)
        let finished = edits.finishSave(claim, succeeded: false)
        #expect(finished)
        let edit = try #require(edits.edit(Self.thread))
        #expect(edit.existingAttachments == [Self.file])
        #expect(edit.originalAttachments == [Self.image, Self.file])
        #expect(!edits.isSaving(Self.thread))
    }
}
