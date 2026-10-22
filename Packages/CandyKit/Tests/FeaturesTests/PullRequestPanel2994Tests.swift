import Foundation
import Testing
@testable import T3Protocol
@testable import Features

/// 2994: bot and resolved comment filters (PullRequestSummaryTab.tsx:428-439, 935-940).
struct PullRequestCommentFilterTests {
    @Test func hidesBotsAndFinishedByDefault() throws {
        var d = try PullRequestFixtures.detail()
        let human = PullRequestActor(login: "octocat"), bot = PullRequestActor(login: "ci[bot]"), flagged = PullRequestActor(login: "app", isBot: true)
        d.comments = [
            PullRequestComment(id: "a", kind: "issue-comment", author: human, body: "hi", createdAt: "2026-10-11T00:00:00Z"),
            PullRequestComment(id: "b", kind: "issue-comment", author: bot, body: "report", createdAt: "2026-10-11T00:00:01Z"),
            PullRequestComment(id: "c", kind: "issue-comment", author: flagged, body: "report", createdAt: "2026-10-11T00:00:02Z"),
            PullRequestComment(id: "d", kind: "review-comment", author: human, body: "nit", createdAt: "2026-10-11T00:00:03Z"),
            PullRequestComment(id: "e", kind: "review", author: human, body: "", createdAt: "2026-10-11T00:00:04Z", reviewState: "DISMISSED"),
        ]
        var thread = PullRequestReviewThread(id: "t", path: "a", line: 1, side: "right", isResolved: true, isOutdated: false, comments: [])
        thread.comments = [PullRequestThreadComment(id: "d", author: human, body: "nit", createdAt: "2026-10-11T00:00:03Z")]
        d.reviewThreads = [thread]
        typealias F = PullRequestDetailLogic.CommentFilter
        let ids = { (f: F) in PullRequestDetailLogic.filterComments(d, f).shown.map(\.root.id) }
        #expect(ids(F()) == ["a"])
        #expect(PullRequestDetailLogic.filterComments(d, F()).hidden == 4)
        #expect(ids(F(bots: true)) == ["a", "b", "c"])
        #expect(ids(F(resolved: true)) == ["a", "d", "e"])
        #expect(ids(F(bots: true, resolved: true)) == ["a", "b", "c", "d", "e"])
        // Finished remarks collapse (CollapsedComment, PullRequestSummaryTab.tsx:204-273, 568-591).
        thread.line = 12
        thread.isOutdated = true
        d.reviewThreads = [thread]
        #expect(PullRequestDetailLogic.collapsed(d.comments[3], thread: thread)
                == .init(label: "Resolved", location: "a:12", outdated: true))
        #expect(PullRequestDetailLogic.collapsed(d.comments[4], thread: nil) == .init(label: "Review dismissed", location: nil, outdated: false))
        #expect(PullRequestDetailLogic.collapsed(d.comments[0], thread: nil) == nil)
        #expect(PullRequestDetailLogic.collapsedSummary("<!-- x -->\n> [!NOTE]\n## Use **this** [link](http://a) and `code`\n- item")
                == "Use this link and code item")
        #expect(PullRequestDetailLogic.allCommentsHiddenNote(1) == "The only comment is hidden by the filter.")
        #expect(PullRequestDetailLogic.allCommentsHiddenNote(3) == "All 3 comments are hidden by the filter.")
        let defaults = try #require(UserDefaults(suiteName: "prpanel-filter-test"))
        defaults.removePersistentDomain(forName: "prpanel-filter-test")
        #expect(F.load(defaults) == F())
        F(bots: true).save(defaults)
        #expect(F.load(defaults) == F(bots: true))
        defaults.removePersistentDomain(forName: "prpanel-filter-test")
    }
}

/// 2994: actions confirm in place (useInlineActionConfirm.ts).
@MainActor
struct InlineActionConfirmTests {
    @Test func gallerySampleDecodes() throws {
        let d = try #require(PullRequestsGallery.sample)
        #expect(d.state == "open" && d.comments.count == 5)
        #expect(PullRequestDetailLogic.filterComments(d, .init()).shown.map(\.id) == ["IC_2", "RT_2"])
    }

    @Test func armsThenConfirms() async throws {
        let confirm = InlineActionConfirm()
        var disarmed: [String] = []
        let press = { (action: String, slot: String) in
            confirm.press(action, slot: slot, contains: { _ in true }, onDisarm: { disarmed.append(slot) })
        }
        #expect(!press("merge", "header"))
        #expect(confirm.isArmed("merge", slot: "header"))
        // The same action from another control arms that one instead.
        #expect(!press("merge", "menu:merge"))
        #expect(disarmed == ["header"])
        #expect(press("merge", "menu:merge"))
        #expect(!confirm.isArmed("merge", slot: "menu:merge"))
        #expect(disarmed == ["header"]) // confirming puts no label back; the action takes over
        #expect(!press("close", "menu:close"))
        confirm.disarm()
        #expect(disarmed == ["header", "menu:close"])
        #expect(!press("close", "menu:close")) // disarmed: the next press arms again
        confirm.disarm()
        confirm.timeoutSeconds = 0.05
        #expect(!press("revert", "menu:revert"))
        try await Task.sleep(for: .milliseconds(300))
        #expect(!confirm.isArmed("revert", slot: "menu:revert"))
        #expect(disarmed.last == "menu:revert")
    }
}
