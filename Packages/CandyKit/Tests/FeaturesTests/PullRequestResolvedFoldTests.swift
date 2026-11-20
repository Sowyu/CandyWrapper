import AppKit
import Testing
import DesignSystem
@testable import T3Protocol
@testable import Features

/// #34644: resolved conversations fold into their authors' avatars on the commented line; a click shows them.
@MainActor
struct PullRequestResolvedFoldTests {
    @Test func resolvedThreadsFoldIntoAvatars() throws {
        var d = try PullRequestFixtures.detail()
        let a = PullRequestActor(login: "octocat"), b = PullRequestActor(login: "hubot")
        d.reviewThreads = [
            PullRequestReviewThread(id: "r", path: "a.ts", line: 1, side: "right", isResolved: true, isOutdated: false,
                                    comments: [PullRequestThreadComment(id: "c1", author: a, body: "nit", createdAt: "2026-10-11T00:00:01Z"),
                                               PullRequestThreadComment(id: "c2", author: b, body: "done", createdAt: "2026-10-11T00:00:02Z")]),
            PullRequestReviewThread(id: "o", path: "a.ts", line: 1, side: "right", isResolved: false, isOutdated: false,
                                    comments: [PullRequestThreadComment(id: "c3", author: a, body: "open", createdAt: "2026-10-11T00:00:03Z")]),
        ]
        let view = PullRequestCodeView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
        view.set(patches: ["diff --git a/a.ts b/a.ts\n--- a/a.ts\n+++ b/a.ts\n@@ -1 +1 @@\n-a\n+b\n"], loading: false, error: nil, nextCursor: nil,
                 moreLoading: false, moreError: nil, commit: nil, commits: [])
        let noop = PullRequestReviewThreadActions(reply: { _, _, _ in }, setResolved: { _, _ in }, loadMore: { _, _, _ in }, editComment: { _, _, _ in }, react: { _, _, _, _ in })
        view.setReview(d, reviewKey: "k", actions: noop, nowMs: 0)
        let list = try #require(view.subviews.compactMap { $0 as? ScrollAreaView }.compactMap { $0.scrollView.documentView as? DiffListView }.first)
        list.setCollapsedFiles([])
        list.layoutSubtreeIfNeeded()
        #expect(!list.placedAnnotationIds.contains("thread:r"))
        #expect(list.placedAnnotationIds.contains("thread:o"))
        let button = try #require(list.subviews.compactMap { $0 as? PullRequestResolvedThreadsButton }.first)
        #expect(button.label == "Resolved conversation")
        #expect(button.lineOverlayWidth == 28) // two authors
        #expect(button.frame.maxX == list.bounds.width - 12)
        _ = button.accessibilityPerformPress()
        list.layoutSubtreeIfNeeded()
        #expect(list.placedAnnotationIds.contains("thread:r"))
        #expect(button.expanded)
    }
}
