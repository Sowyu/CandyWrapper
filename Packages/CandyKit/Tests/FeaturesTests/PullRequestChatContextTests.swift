import Foundation
import Testing
import T3Protocol
@testable import Features

/// #30579: Add to chat hands the composer the pull request chip and the remark
/// (4928 pullRequestDetail.logic.ts:693-1345, composerContextRecords.ts:100-120, 401-420).
@MainActor
struct PullRequestChatContextTests {
    typealias C = PullRequestChatContext

    @Test func readableBodyDropsBotBookkeeping() {
        #expect(C.readableBody("<!-- only -->") == nil)
        #expect(C.readableBody("Looks good\n<!-- bot:state -->\nThanks") == "Looks good\nThanks")
        #expect(C.readableBody("a <!-- x --> b") == "a  b")
        #expect(C.readableBody("```html\n<!-- keep -->\n```\nok") == "```html\n<!-- keep -->\n```\nok")
        #expect(C.readableBody("text <!-- unterminated") == "text")
    }

    @Test func boundedCutsAtAThousandUnits() {
        let long = String(repeating: "a", count: 1_200)
        let b = C.bounded(long)
        #expect(b.utf16.count == 1_000)
        #expect(b.hasSuffix("..."))
        #expect(C.boundedField("a \n  b") == "a b")
    }

    @Test func commentRecords() throws {
        let d = try PullRequestFixtures.detail()
        let records = C.records(d, commentId: "IC_1")
        #expect(records.count == 2)
        let pr = records[0], c = records[1]
        #expect(pr["contextId"]?.stringValue == ComposerContext.kindScopedId("review-comment", "pull-request-context:\(d.url)"))
        #expect(pr["label"]?.stringValue == "#\(d.number)")
        #expect(pr["text"]?.stringValue?.hasPrefix("The pull request is #\(d.number), titled `") == true)
        #expect(pr["pullRequest"]?["url"]?.stringValue == d.url)
        #expect(c["contextId"]?.stringValue == ComposerContext.kindScopedId("review-comment", "pr-comment:\(d.url):comment:IC_1"))
        #expect(c["sectionTitle"]?.stringValue == "PR #\(d.number) conversation")
        #expect(c["rangeLabel"]?.stringValue == "comment")
        let author = d.comments.first { $0.id == "IC_1" }?.author?.login ?? "ghost"
        #expect(c["filePath"]?.stringValue == "@\(author)")
        #expect(c["text"]?.stringValue == "\(author): Preview deployed.")
        #expect(c["fenceLanguage"] == nil)
    }

    @Test func aLineRemarkTravelsAsItsConversation() throws {
        let d = try PullRequestFixtures.detail()
        let records = C.records(d, commentId: "RC_1")
        let t = try #require(records.last)
        #expect(t["contextId"]?.stringValue == ComposerContext.kindScopedId("review-comment", "pr-comment:\(d.url):thread:RT_1"))
        #expect(t["sectionTitle"]?.stringValue == "PR #\(d.number) review")
        #expect(t["rangeLabel"]?.stringValue == "L12")
        #expect(t["startIndex"]?.doubleValue == 11)
        #expect(t["fenceLanguage"]?.stringValue == "tsx")
        #expect(t["label"]?.stringValue == "#\(d.number) _chat.pull-requests.tsx L12")
        var left = try #require(d.reviewThreads.first)
        left.side = "left"
        #expect(C.threadRecord(d, left)?["rangeLabel"]?.stringValue == "L12 (before)")
    }

    @Test func chatSubjectNeedsWords() throws {
        var d = try PullRequestFixtures.detail()
        let c = try #require(d.comments.first)
        #expect(PullRequestDetailLogic.chatSubject(c, d))
        d.comments[0].body = "<!-- bot -->"
        #expect(!PullRequestDetailLogic.chatSubject(d.comments[0], d))
        #expect(C.records(d, commentId: d.comments[0].id).isEmpty)
    }
}

/// #26060 for comments: a comment breaks lines where its host does, as the description does.
@MainActor
struct PullRequestCommentLineBreakTests {
    @Test func commentsKeepSingleLineBreaksWhenTheHostDoes() {
        let c = PullRequestComment(id: "1", kind: "issue-comment", author: PullRequestActor(login: "a"), body: "line one\nline two", createdAt: "2026-10-10T00:00:00Z")
        let soft = CommentCard(c, nowMs: 0, cwd: "/")
        let hard = CommentCard(c, nowMs: 0, cwd: "/", lineBreaks: true)
        #expect(hard.height(forWidth: 600) > soft.height(forWidth: 600))
        #expect(PullRequestDetailLogic.hardLineBreaks("github"))
        #expect(!PullRequestDetailLogic.hardLineBreaks("gitlab"))
    }
}
