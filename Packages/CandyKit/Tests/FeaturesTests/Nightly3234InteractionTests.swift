import AppKit
import Testing
import T3Protocol
@testable import Features

@MainActor
struct Nightly3234InteractionTests {
    @Test func periodicRefreshLeavesFinalPullRequestsCached() {
        #expect(PullRequestListLogic.periodicRefreshState("closed") == nil)
        #expect(PullRequestListLogic.periodicRefreshState("merged") == nil)
        #expect(PullRequestListLogic.periodicRefreshState("all") == "open")
        #expect(PullRequestListLogic.periodicRefreshState("open") == "open")
    }
    @Test func branchDeletionRequiresFinalStateAndBothPermissions() throws {
        var detail = try PullRequestFixtures.detail()
        detail.state = "merged"
        detail.capabilities.deleteBranch = true
        detail.capabilities.actions = ["delete-branch"]
        detail.viewerPermissions.actions = ["delete-branch"]
        #expect(PullRequestDetailLogic.canDeleteBranch(detail))
        detail.state = "closed"
        #expect(PullRequestDetailLogic.canDeleteBranch(detail))
        detail.state = "open"
        #expect(!PullRequestDetailLogic.canDeleteBranch(detail))
        detail.state = "merged"; detail.capabilities.deleteBranch = nil
        #expect(!PullRequestDetailLogic.canDeleteBranch(detail))
        detail.capabilities.deleteBranch = true; detail.viewerPermissions.actions = []
        #expect(!PullRequestDetailLogic.canDeleteBranch(detail))
        detail.viewerPermissions.actions = ["delete-branch"]; detail.capabilities.actions = []
        #expect(!PullRequestDetailLogic.canDeleteBranch(detail))
    }

    @Test func draggedPullRequestBecomesContextAndRejectsUnsafeURLs() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        var pr = PullRequestReference(number: 7, title: "Add tests", url: "https://github.com/example/repo/pull/7",
            headBranch: "tests", baseBranch: "main", state: "open", isDraft: false)
        board.setData(try JSONEncoder().encode(pr), forType: PullRequestDrag.type)
        let read = try #require(PullRequestDrag.read(board))
        #expect(ComposerContext.pullRequestRecord(read)["kind"]?.stringValue == "review-comment")
        #expect(ComposerContext.pullRequestReference(read).label.contains("7"))
        pr.url = "https://github.com/example/another/pull/7"
        #expect(ComposerContext.pullRequestReference(pr).contextId != ComposerContext.pullRequestReference(read).contextId)
        pr.url = "file:///etc/passwd"
        board.setData(try JSONEncoder().encode(pr), forType: PullRequestDrag.type)
        #expect(PullRequestDrag.read(board) == nil)
        board.setData(Data(repeating: 120, count: 65_536), forType: PullRequestDrag.type)
        #expect(PullRequestDrag.read(board) == nil)
    }
}
