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
}
