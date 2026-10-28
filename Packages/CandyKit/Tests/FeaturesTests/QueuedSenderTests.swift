import Foundation
import Testing
import T3Protocol
import T3Store
@testable import Features

struct QueuedSenderTests {
    @Test func queuedRowsPreserveSenderMetadataAndStripLegacyAutomationPrefix() throws {
        for (fields, expected, attribution) in [
            (#""createdBy":"agent","senderThreadId":"sender","text":"Review this""#, "Review this", UserMessagePresentation.Attribution.agent),
            (#""createdBy":"agent","creationSource":"server","text":"Continue""#, "Continue", .t3code),
            (#""scheduledTaskId":"task","text":"Scheduled prompt""#, "Scheduled prompt", .automation),
            (#""createdBy":"agent","text":"[Triggered by schedule task: task]\n\nActual prompt""#, "Actual prompt", .automation),
            (#""context":{"guest":{"guestMessageId":"guest-message","name":"Visitor","text":"Guest words"}},"text":"Attributed prompt""#, "Guest words", .guest)
        ] {
            let json = #"{"thread":{"id":"t"},"runs":[{"id":"r","threadId":"t","ordinal":1,"userMessageId":"m","status":"queued","requestedAt":"2026-10-27T00:00:00Z"}],"messages":[{"id":"m","threadId":"t","role":"user","streaming":false,"createdAt":"2026-10-27T00:00:00Z","updatedAt":"2026-10-27T00:00:00Z",\#(fields)}],"updatedAt":"2026-10-27T00:00:00Z"}"#
            let projection = try JSONDecoder().decode(ThreadProjection.self, from: Data(json.utf8))
            let item = try #require(ComposerLogic.QueueState(projection: projection).items.first)
            let message = try #require(item.message)
            #expect(item.text == expected)
            #expect(UserMessagePresentation.resolve(message).attribution == attribution)
            #expect(item.isEditable == (attribution != .guest))
            #expect(message.createdAt == "2026-10-27T00:00:00Z")
        }
    }
}
