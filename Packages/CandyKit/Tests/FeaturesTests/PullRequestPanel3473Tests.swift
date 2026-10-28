import Foundation
import Testing
@testable import T3Protocol
@testable import Features

/// 3473 pull request panel: review thread replies under their finding (70a869d262), the change
/// breakdown (92a6f6d731) and the checks count (618c46478a).
struct PullRequestPanel3473Tests {
    @Test func repliesNestUnderTheirFinding() throws {
        var d = try PullRequestFixtures.detail()
        let human = PullRequestActor(login: "octocat"), bot = PullRequestActor(login: "review[bot]")
        d.comments = [
            PullRequestComment(id: "a", kind: "issue-comment", author: human, body: "first", createdAt: "2026-10-11T00:00:00Z"),
            PullRequestComment(id: "r1", kind: "review-comment", author: bot, body: "finding", createdAt: "2026-10-11T00:00:01Z", path: "a.ts"),
            PullRequestComment(id: "b", kind: "issue-comment", author: human, body: "later", createdAt: "2026-10-11T00:00:05Z"),
        ]
        var thread = PullRequestReviewThread(id: "t", path: "a.ts", line: 3, side: "right", isResolved: false, isOutdated: false, comments: [])
        // The reply exists only in the thread, and arrives before the finding.
        thread.comments = [PullRequestThreadComment(id: "r2", author: human, body: "fixed", createdAt: "2026-10-11T00:00:02Z", url: "https://h/r2"),
                           PullRequestThreadComment(id: "r1", author: bot, body: "finding", createdAt: "2026-10-11T00:00:01Z")]
        thread.commentCount = 4
        d.reviewThreads = [thread]
        let items = PullRequestDetailLogic.conversationItems(d.comments, d.reviewThreads)
        #expect(items.map(\.id) == ["a", "t", "b"])
        guard case .thread(let root, let replies, _, let more) = items[1] else { Issue.record("no thread"); return }
        #expect(root.id == "r1" && replies.map(\.id) == ["r2"] && replies[0].path == "a.ts" && replies[0].kind == "review-comment")
        #expect(more == .init(moreReplies: 2, hasMoreReplies: true, url: "https://h/r2"))
        #expect(PullRequestDetailLogic.moreRepliesLabel(2) == "2 more replies")
        #expect(PullRequestDetailLogic.moreRepliesLabel(0) == "More replies")
        // A person's reply keeps a bot's finding in view; the hidden count is in remarks.
        let filtered = PullRequestDetailLogic.filterComments(d, .init())
        #expect(filtered.shown.map(\.id) == ["a", "t", "b"] && filtered.hidden == 0)
        thread.comments.removeFirst()
        thread.commentCount = nil
        d.reviewThreads = [thread]
        #expect(PullRequestDetailLogic.filterComments(d, .init()).shown.map(\.id) == ["a", "b"])
        #expect(PullRequestDetailLogic.filterComments(d, .init()).hidden == 1)
        // A bot's approval is a verdict and stays with bots hidden (#25829 at 3814); its chatter doesn't.
        var verdicts = d
        verdicts.reviewThreads = []
        verdicts.comments = [PullRequestComment(id: "v", kind: "review", author: bot, body: "", createdAt: "2026-10-11T00:00:06Z", reviewState: "APPROVED"),
                             PullRequestComment(id: "c", kind: "issue-comment", author: bot, body: "chatter", createdAt: "2026-10-11T00:00:07Z")]
        #expect(PullRequestDetailLogic.filterComments(verdicts, .init()).shown.map(\.id) == ["v"])
        // On the timeline the finding carries its thread and stays out of the folded runs.
        d.reviewThreads = [PullRequestReviewThread(id: "t", path: "a.ts", line: 3, side: "right", isResolved: true, isOutdated: false,
                                                   comments: [PullRequestThreadComment(id: "r1", author: bot, body: "finding", createdAt: "2026-10-11T00:00:01Z"),
                                                              PullRequestThreadComment(id: "r2", author: human, body: "fixed", createdAt: "2026-10-11T00:00:02Z")])]
        let events = PullRequestDetailLogic.timeline(d)
        let finding = try #require(events.first { $0.id == "r1" })
        #expect(finding.thread?.replies.map(\.id) == ["r2"] && finding.thread?.isResolved == true && finding.thread?.more.hasMoreReplies == false)
        #expect(!events.contains { $0.id == "r2" })
        let rows = PullRequestDetailLogic.groupConversations(events)
        #expect(rows.contains { if case .event(let e) = $0 { e.id == "r1" } else { false } })
        #expect(!rows.contains { if case .comments(let run) = $0 { run.contains { $0.id == "r1" } } else { false } })
    }

    @Test func activityCountsEveryRemarkInHand() throws {
        var d = try PullRequestFixtures.detail()
        let activity = PullRequestActivity(author: nil, reviewers: nil,
                                           comments: [PullRequestComment(id: "a", kind: "issue-comment", author: nil, body: "x", createdAt: "t")],
                                           commentCount: 1, commentsTruncated: false, reviewThreadsTruncated: nil,
                                           reviewThreads: [PullRequestReviewThread(id: "t", path: "p", line: nil, side: "right", isResolved: false, isOutdated: false,
                                                                                   comments: [PullRequestThreadComment(id: "b", author: nil, body: "y", createdAt: "t")])],
                                           commits: [], reactions: nil)
        d.apply(activity)
        #expect(d.commentCount == 2)
    }

    @Test func checksCountAndBreakdown() throws {
        let c = { (s: String) in PullRequestCheck(name: s, status: s) }
        #expect(PullRequestDetailLogic.checksCountLabel([c("success"), c("pending"), c("action-required")]) == "1/3")
        #expect(PullRequestDetailLogic.checksCountLabel([c("success"), c("failure"), c("cancelled")]) == "2 failed")
        #expect(PullRequestDetailLogic.checksCountLabel([c("success")]) == "")
        // Older servers send no docs; kinds without lines leave no row.
        let b = try JSONDecoder().decode(PullRequestChangeBreakdown.self, from: Data(#"""
        {"code":{"additions":10,"deletions":2},"tests":{"additions":4,"deletions":0},"mocks":{"additions":0,"deletions":0},"generated":{"additions":0,"deletions":9}}
        """#.utf8))
        #expect(b.rows.map(\.label) == ["Code", "Tests", "Generated"])
        #expect(b.docs == .init(additions: 0, deletions: 0))
    }
}
