import AppKit
import Foundation
import Testing
import T3Protocol
import T3Store
import DesignSystem
@testable import Features

@MainActor
struct ThreadCompletionTests {
    private func json(_ text: String) throws -> JSONValue { try JSONValue(parsing: Data(text.utf8)) }

    @Test func progressiveCapabilityIsTopLevel() throws {
        let config = try json(#"{"providers":[],"threadFind":true,"threadFindProgressive":true}"#).decode(as: ServerProviderConfig.self)
        #expect(config.capabilities.contains("threadFind"))
        #expect(config.capabilities.contains("threadFindProgressive"))
        let older = try json(#"{"providers":[]}"#).decode(as: ServerProviderConfig.self)
        #expect(!older.capabilities.contains("threadFind"))
    }
    @Test func progressiveResponseRetainsIdentityWithoutFinalCount() throws {
        let first = try json(#"{"complete":false,"snapshotSequence":4,"totalMatches":1,"activeIndex":0,"match":{"entryId":"e","runId":null,"occurrence":0}}"#).decode(as: ThreadFindResult.self)
        let final = try json(#"{"complete":true,"snapshotSequence":4,"totalMatches":25,"activeIndex":7,"match":{"entryId":"e","runId":null,"occurrence":0}}"#).decode(as: ThreadFindResult.self)
        #expect(first.match == final.match)
        #expect(first.complete == false && final.complete == true)
        let bar = ThreadFindBarView(frame: NSRect(x: 0, y: 0, width: 384, height: 36))
        bar.present(query: "e", index: 0, total: 1, counting: true)
        let labels = bar.subviews.compactMap { ($0 as? LabelView)?.text }
        #expect(labels.contains("1/…"))
    }
    @Test func restoringAttachmentsRekeysOnlyLinksAndKeepsOtherContext() throws {
        let context = try json(#"{"records":[{"kind":"file","contextId":"file_old","attachmentId":"old","label":"a.txt"},{"kind":"thread","contextId":"thread_ref","threadId":"t"}]}"#)
        let attachments = [try json(#"{"type":"file","id":"old","name":"a.txt"}"#)]
        let fresh = ComposerAttachment(id: "new", kind: .file, name: "a.txt", mimeType: "text/plain", sizeBytes: 4,
            fileURL: URL(fileURLWithPath: "/unused"), status: .ready, attachmentId: "uploaded", environmentId: "sandbox")
        let recovered = ThreadPromptAttachmentRestore.restore(text: "file_old [a.txt](t3-context://v1/file/file_old)", context: context, attachments: attachments, staged: [fresh])
        #expect(recovered.text == "file_old [a.txt](t3-context://v1/file/file_new)")
        #expect(recovered.records.first?["attachmentId"]?.stringValue == "uploaded")
        #expect(recovered.records.last?["threadId"]?.stringValue == "t")
    }
    @Test func imageOnlyPromptDoesNotRestoreBootstrapText() {
        let image = ComposerAttachment(kind: .image, name: "a.png", mimeType: "image/png", sizeBytes: 4,
            fileURL: URL(fileURLWithPath: "/unused"), status: .ready, attachmentId: "fresh", environmentId: "sandbox")
        let result = ThreadPromptAttachmentRestore.restore(text: ComposerAttachmentRules.attachmentOnlyPrompt, context: nil, attachments: [], staged: [image])
        #expect(result.text.isEmpty)
    }
    @Test func citationRoundTripsUnicodeAndCommentWithoutMovingSelector() throws {
        let original = ThreadAssistantCitation(environmentId: "env", threadId: "t", messageId: "m", text: "A + café 🌿", start: 4, end: 16, prefix: "pre", suffix: "post", comment: nil)
        let changed = original.withComment("  Why this?\nExplain.  ")
        #expect(changed.start == original.start && changed.end == original.end)
        #expect(ThreadAssistantCitation.parse(changed.href) == changed)
        #expect(changed.comment == "Why this?\nExplain.")
        #expect(changed.withComment(" \n").comment == nil)
        let tokens = ComposerInlineTokens.collect(changed.markdown)
        #expect(tokens.count == 1)
        #expect(tokens.first?.kind == .citation(changed))
        #expect(ComposerChipLook.basic(try #require(tokens.first)).label == "Why this? Explain.")
    }
    @Test func citationRejectsAmbiguousOrOversizedSelectors() {
        let c = ThreadAssistantCitation(environmentId: "e", threadId: "t", messageId: "m", text: "Hello", start: 0, end: 5, prefix: "", suffix: "", comment: nil)
        #expect(ThreadAssistantCitation.parse(c.href + "&text=Other") == nil)
        #expect(ThreadAssistantCitation.parse(c.href + "&unknown=x") == nil)
        #expect(ThreadAssistantCitation.parse(c.href + "#fragment") == nil)
        #expect(ThreadAssistantCitation.parse(c.withComment(String(repeating: "x", count: 8001)).href) == nil)
        #expect(ThreadAssistantCitation.parse(c.href.replacingOccurrences(of: "end=5", with: "end=0")) == nil)
        #expect(ThreadAssistantCitation.parse(c.href.replacingOccurrences(of: "text=Hello", with: "text=Hello+world"))?.text == "Hello world")
    }
    @Test func minimapPairsEachUserWithLastAssistant() throws {
        let timestamp = T3Timestamp("2026-10-11T12:00:00Z")
        func row(_ id: String, _ role: ChatMessage.Role, _ text: String) -> TimelineRow {
            TimelineRow(id: id, createdAt: timestamp, kind: .message(ChatMessage(id: MessageId(id), role: role, text: text, createdAt: timestamp), projectedItem: nil, showAssistantMeta: false, showAssistantCopyButton: false, assistantCopyStreaming: false, turnDiffSummary: nil))
        }
        let items = ThreadMinimapItem.derive([row("u", .user, "  A\n B "), row("a", .assistant, "First"), row("b", .assistant, "Last"), row("v", .user, "Next")])
        #expect(items.count == 2)
        #expect(items[0].userText == "  A\n B ")
        #expect(items[0].assistantText == "Last")
        #expect(items[0].preview == "A B\n\nLast")
        #expect(items[1].assistantText == nil)
        let view = ThreadMinimapView()
        view.items = items
        view.updatePreview(at: 0, text: "Streaming", assistant: true)
        #expect(view.items[0].preview == "A B\n\nStreaming")
        #expect(view.items[1] == items[1])
    }
    @Test func taskSummaryUsesRunningThenPendingThenLast() {
        let steps = [ThreadTaskStep(text: "A", status: "pending"), ThreadTaskStep(text: "B", status: "running")]
        #expect(ThreadTaskStep.summary(steps) == "B")
        #expect(ThreadTaskStep.summary([steps[0]]) == "A")
        #expect(ThreadTaskStep.summary([ThreadTaskStep(text: "Done", status: "completed")]) == "Done")
    }
    @Test func permissionNoticeRequiresExplicitLegacyGrant() throws {
        func state(_ extra: String) throws -> AuthSessionState {
            try json("{\"authenticated\":true,\"auth\":{\"policy\":\"token\",\"bootstrapMethods\":[],\"sessionMethods\":[]}," + extra + "}").decode(as: AuthSessionState.self)
        }
        #expect(try state(#""permissions":["orchestration:operate"]"#).hasLegacyPermissions)
        #expect(try !state(#""scopes":["orchestration:operate"]"#).hasLegacyPermissions)
        #expect(try !state(#""permissions":["orchestration:operate","filesystem:read"]"#).hasLegacyPermissions)
        #expect(try !state(#""permissions":[]"#).hasLegacyPermissions)
    }
    @Test func setupSnapshotDecodesProgressAndTail() throws {
        let value = try json(#"{"threadId":"t","phase":"running","sequence":7,"stages":[{"id":"checkout","status":"running","percent":35,"detail":"files","tail":[]},{"id":"setup-script","status":"failed","percent":null,"detail":"exit 1","tail":["failed"]}],"error":null}"#).decode(as: ThreadWorktreeSetupSnapshot.self)
        #expect(value.stages[0].label == "Check out files")
        #expect(value.stages[1].tail == ["failed"])
        #expect(!value.agentStarted)
    }
    @Test func inspectorEqualityIncludesToneAndActions() {
        var a = WorkDetail(); a.blocks = [("42", .output)]
        var b = a; b.blocks = [("42", .error)]
        #expect(a != b)
        b = a; b.links = [0: "https://example.com"]
        #expect(a != b)
        b = a; b.diffPath = "a.swift"
        #expect(a != b)
    }
}
