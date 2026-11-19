import AppKit
import Testing
import DesignSystem
import T3Protocol
import T3Store
@testable import Features

/// TimelineUserMessageRow.tsx:519-575 and 732-836 at 4928 (#27306, #27324, #27377, #38558).
@MainActor
struct UserMessageShapeTests {
    static func image(_ id: String) -> JSONValue {
        .object(["type": .string("image"), "id": .string(id), "name": .string("\(id).png"), "mimeType": .string("image/png"), "sizeBytes": .number(10)])
    }
    static func file(_ id: String, name: String = "notes.pdf", mime: String = "application/pdf", pasted: Bool = false) -> JSONValue {
        var o: [String: JSONValue] = ["type": .string("file"), "id": .string(id), "name": .string(name), "mimeType": .string(mime), "sizeBytes": .number(2048)]
        if pasted { o["source"] = .object(["_tag": .string("pasted-text")]) }
        return .object(o)
    }
    static func message(_ text: String, _ attachments: [JSONValue], records: [JSONValue] = []) -> ChatMessage {
        var m = ChatMessage(id: MessageId("m"), role: .user, text: text, createdAt: T3Timestamp("2026-10-29T12:00:00Z"))
        m.attachments = attachments
        if !records.isEmpty { m.context = .object(["records": .array(records)]) }
        return m
    }

    @Test func shapesFollowWhatWasSent() {
        let images = UserMessageShape(Self.message("", [Self.image("a")]), text: "", own: true)
        #expect(images.mediaOnly && !images.mediaAboveText && images.loneImage && !images.drawsBubble)
        let withWords = UserMessageShape(Self.message("look", [Self.image("a"), Self.image("b")]), text: "look", own: true)
        #expect(withWords.mediaAboveText && withWords.collage && withWords.drawsBubble)
        let cards = UserMessageShape(Self.message("", [Self.file("f")]), text: "", own: true)
        #expect(cards.fileCardsOnly && !cards.drawsBubble)
        // A file chip and nothing else still reads as cards; words beside it keep the bubble.
        let record: JSONValue = .object(["kind": .string("file"), "contextId": .string("c1"), "attachmentId": .string("f")])
        let chipText = "[notes.pdf](t3-context://v1/file/c1)"
        #expect(UserMessageShape(Self.message(chipText, [Self.file("f")], records: [record]), text: chipText, own: true).fileCardsOnly)
        let worded = UserMessageShape(Self.message("read " + chipText, [Self.file("f")], records: [record]), text: "read " + chipText, own: true)
        #expect(!worded.fileCardsOnly && worded.drawsBubble && worded.unchippedFiles.isEmpty)
        // Agents' and guests' messages keep the bubble around everything.
        let agent = UserMessageShape(Self.message("", [Self.image("a")]), text: "", own: false)
        #expect(!agent.mediaOnly && !agent.mediaAboveText && agent.drawsBubble)
        // A file and an image together: media above, the file inside the bubble.
        let mixed = UserMessageShape(Self.message("", [Self.image("a"), Self.file("f")]), text: "", own: true)
        #expect(mixed.mediaAboveText && !mixed.fileCardsOnly && mixed.unchippedFiles.count == 1)
        #expect(UserMessageShape.fileLabel(Self.file("p", name: "paste.txt", pasted: true)) == "Pasted text")
    }

    static func row(_ m: ChatMessage) -> UserMessageRowView {
        let item = TimelineItem(row: TimelineRow(id: "m", createdAt: m.createdAt,
            kind: .message(m, projectedItem: nil, showAssistantMeta: false, showAssistantCopyButton: false,
                           assistantCopyStreaming: false, turnDiffSummary: nil)))
        let view = UserMessageRowView()
        view.context = TimelineContext()
        view.configure(item)
        return view
    }

    @Test func geometry() {
        // A lone image before its pixels arrive: 192pt tall at the 96pt minimum, no bubble padding, the hover line under it.
        let lone = Self.row(Self.message("", [Self.image("lone")]))
        #expect(lone.bubbleWidth(forWidth: 600) == 96)
        let loneHeight: CGFloat = 192 + 4 + 24 + 16
        #expect(lone.height(forWidth: 600) == loneHeight)
        // Two images and words: a 320 x 192 collage, `gap-1`, then the bubble with its 12pt padding.
        let plain = Self.row(Self.message("look", [])).height(forWidth: 600)
        let collage = Self.row(Self.message("look", [Self.image("a"), Self.image("b")]))
        let above: CGFloat = 192 + 4
        #expect(collage.height(forWidth: 600) == plain + above)
        // Three images: the first spans two 95.5pt rows with a hairline between.
        let three = Self.row(Self.message("look", [Self.image("a"), Self.image("b"), Self.image("c")]))
        #expect(three.height(forWidth: 600) == plain + above)
        // File cards: 256pt wide and 52pt tall with `gap-1`.
        let cards = Self.row(Self.message("", [Self.file("f"), Self.file("g")]))
        #expect(cards.bubbleWidth(forWidth: 600) == 256)
        let cardsHeight: CGFloat = 52 * 2 + 4 + 4 + 24 + 16
        #expect(cards.height(forWidth: 600) == cardsHeight)
    }
}
