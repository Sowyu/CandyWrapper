import Foundation
import Testing
import T3Protocol
import T3Store
@testable import Features

/// #39569 (T3 5258 questionAttachments.ts:186-215): a question that closed unanswered gives its files and screenshots
/// back to the thread's draft, each exactly once.
struct QuestionFilesReturnTests {
    func file(_ id: String, _ status: ComposerFileRow.Status, minted: String? = nil, image: Bool = false) -> ComposerAttachment {
        ComposerAttachment(id: id, kind: image ? .image : .file, name: id, mimeType: image ? "image/png" : "text/plain", sizeBytes: 1,
                           fileURL: URL(fileURLWithPath: "/tmp/\(id)"), status: status, attachmentId: minted, environmentId: "e")
    }

    @Test func everyFileLandsInExactlyOnePlace() {
        let files = [file("shot", .ready, minted: "a1", image: true), file("uploading", .uploading(0.4), minted: "a2"),
                     file("failed", .failed("offline"))]
        let (kept, released) = ComposerAttachmentRules.returningQuestionFiles(files, draftCount: 0)
        #expect(kept.map(\.id) == ["shot", "uploading", "failed"])
        #expect(released.isEmpty)
        // A ready screenshot keeps its server copy; the others upload again from the draft.
        #expect(kept[0].status == .ready && kept[0].attachmentId == "a1" && kept[0].kind == .image)
        #expect(kept[1].status == .uploading(0) && kept[1].attachmentId == nil)
        #expect(kept[2].status == .uploading(0))
    }

    @Test func aFullDraftReleasesTheRest() {
        let files = [file("one", .ready, minted: "a1"), file("two", .ready, minted: "a2")]
        let (kept, released) = ComposerAttachmentRules.returningQuestionFiles(files, draftCount: ComposerAttachmentRules.maxAttachments - 1)
        #expect(kept.map(\.id) == ["one"])
        #expect(released.map(\.id) == ["two"])
        #expect(Set(kept.map(\.id)).isDisjoint(with: released.map(\.id)))
    }

    /// Only the question drafts of an unanswered request go back; an answered request's drafts are released.
    @Test func draftKeysNameTheirRequest() {
        let thread = ThreadId("env:t1")
        let key = thread.rawValue + "\u{0}req-1\u{0}q1"
        #expect(ThreadRequestResolutionTracker.requestId(ofDraftKey: key, threadId: thread) == "req-1")
        #expect(ThreadRequestResolutionTracker.requestId(ofDraftKey: key, threadId: ThreadId("env:t2")) == nil)
        #expect(ThreadRequestResolutionTracker.resolvedDraftKeys([key], threadId: thread, pending: ["req-1"]).isEmpty)
        #expect(ThreadRequestResolutionTracker.resolvedDraftKeys([key], threadId: thread, pending: []) == [key])
    }
}
