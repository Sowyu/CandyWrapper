import AppKit
import Testing
@testable import T3Protocol
@testable import Features
import DesignSystem
@testable import T3Store

/// 5258: a pull request's Summary comes back with its order and scroll (#42179,
/// PullRequestSummaryTab.tsx:478-487, PullRequestDetailPanel.tsx:342).
@MainActor
struct PullRequestSummaryMemoryTests {
    @Test func eachPullRequestKeepsItsOrderAndScroll() throws {
        PullRequestSummaryView.memory = [:]
        // The memory is per process; other suites render the same fixture.
        defer { PullRequestSummaryView.memory = [:] }
        var a = try PullRequestFixtures.detail()
        a.body = (0..<80).map { "Paragraph \($0)" }.joined(separator: "\n\n")
        var b = a
        b.url += "-other"
        let panel = PullRequestDetailView(frame: NSRect(x: 0, y: 0, width: 420, height: 400))
        panel.show(a)
        panel.layoutSubtreeIfNeeded()
        panel.summary.stack.scroll(toTop: 300)
        panel.summary.orderButton.action?()
        // Condensing the header refunds its height, so read where it landed.
        let left = panel.summary.scrollTarget.top
        #expect(left > 100 && panel.condensed)
        panel.show(b)
        panel.layoutSubtreeIfNeeded()
        #expect(panel.summary.scrollTarget.top == 0)
        #expect(panel.summary.orderButton.title == "Newest first")
        #expect(!panel.condensed)
        panel.show(a)
        panel.layoutSubtreeIfNeeded()
        #expect(panel.summary.scrollTarget.top == left)
        #expect(panel.condensed)
        #expect(panel.summary.orderButton.title == "Oldest first")
        // A new view, as when the panel closed and reopened, restores it too.
        let reopened = PullRequestDetailView(frame: NSRect(x: 0, y: 0, width: 420, height: 400))
        reopened.show(a)
        reopened.layoutSubtreeIfNeeded()
        #expect(reopened.summary.scrollTarget.top == left)
        #expect(reopened.condensed)
    }
}

/// 5258: a clicked pull request pane scrolls from the keyboard (#39319).
@MainActor
struct PullRequestKeyScrollTests {
    @Test func keysMoveTheFocusedPane() {
        let at = { (key: UInt16, flags: NSEvent.ModifierFlags, top: CGFloat) in
            KeyScroll.target(keyCode: key, flags: flags, top: top, page: 300, max: 1000)
        }
        #expect(at(125, [], 0) == 40)
        #expect(at(126, [], 20) == 0)
        #expect(at(121, [], 0) == 270)
        #expect(at(49, [.shift], 500) == 230)
        #expect(at(119, [], 0) == 1000)
        #expect(at(126, [.command], 500) == 0)
        #expect(at(125, [.option], 0) == nil)
        #expect(at(0, [], 0) == nil)
    }
}

/// 5258: merges and reviews are pinned to the head the reader saw, and a newer head shows the
/// "New commits were pushed" row (#41761, #41773, pullRequestDetail.logic.ts:1550-1565).
@MainActor
struct PullRequestHeadPinTests {
    @Test func seenHeadKeepsTheFirstSettledHead() {
        typealias L = PullRequestDetailLogic
        let first = L.seenHead(nil, key: "a", settledHead: "111")
        #expect(first.sha == "111")
        #expect(L.seenHead(first, key: "a", settledHead: "222").sha == "111")
        #expect(L.seenHead(first, key: "b", settledHead: "333").sha == "333")
        // An unsettled read waits for the first settled one.
        let pending = L.seenHead(nil, key: "a", settledHead: nil)
        #expect(L.seenHead(pending, key: "a", settledHead: "444").sha == "444")
        #expect(L.mergeHeadPin("merge", "111") == "111")
        #expect(L.mergeHeadPin("enable-auto-merge", "111") == "111")
        #expect(L.mergeHeadPin("update-branch", "111") == nil)
    }

    @Test func aNewerHeadShowsTheBannerUntilLoaded() throws {
        var d = try PullRequestFixtures.detail()
        d.state = "open"
        d.headSha = "aaaaaaa1111"
        let panel = PullRequestDetailView(frame: NSRect(x: 0, y: 0, width: 420, height: 600))
        panel.show(d)
        panel.layoutSubtreeIfNeeded()
        let plain = panel.headerHeight
        var loaded: String?
        panel.onLoadNewCommits = { loaded = $0 }
        d.headSha = "bbbbbbb2222"
        panel.show(d)
        panel.layoutSubtreeIfNeeded()
        #expect(panel.shownHeadSha == "aaaaaaa1111")
        #expect(panel.headerHeight > plain)
        let review = PullRequestPayloads.submitReview(PullRequestRef(projectId: "p", repository: "o/r", number: 1), verdict: "approve", body: "",
                                                      expectedHeadSha: panel.shownHeadSha)
        #expect(review["expectedHeadSha"]?.stringValue == "aaaaaaa1111")
        func find(_ v: NSView) -> ButtonView? {
            if let b = v as? ButtonView, b.title == "Load new commits" { return b }
            return v.subviews.lazy.compactMap(find).first
        }
        find(panel)?.action?()
        #expect(loaded == "bbbbbbb2222")
        panel.acceptHead("bbbbbbb2222")
        panel.layoutSubtreeIfNeeded()
        #expect(panel.shownHeadSha == "bbbbbbb2222")
        #expect(panel.headerHeight == plain)
    }
}

/// 5258 #41073: a file link in a pull request's Markdown opens through the pull request view,
/// with the folder the Markdown resolved against.
@MainActor
struct PullRequestMarkdownFileLinkTests {
    @Test func markdownInsideThePanelOpensThroughIt() {
        let panel = PullRequestDetailView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        let markdown = MarkdownView()
        markdown.cwd = "/checkout"
        let holder = NSView()
        holder.addSubview(markdown)
        panel.addSubview(holder)
        #expect(markdown.fileOpener == nil)
        var opened: (String, Bool, String?)?
        panel.onOpenFile = { meta, editor, cwd in opened = (meta.filePath, editor, cwd) }
        markdown.fileOpener?(FileLinkMeta(filePath: "/checkout/a.ts", targetPath: "/checkout/a.ts", workspaceRelativePath: "a.ts",
                                           basename: "a.ts", line: nil, column: nil), false)
        #expect(opened?.0 == "/checkout/a.ts")
        #expect(opened?.2 == "/checkout")
    }
}

/// 5258 #42875, #42745: the Pull Requests and Issues pages report the tabs they close, for Mod+Shift+T.
@MainActor
struct PageClosedTabTests {
    @Test func closingAPageTabReportsIt() {
        let container = PullRequestsPageContainer()
        var closed: [RightPanelSurface] = []
        container.onClosed = { closed += $0 }
        let target = PullRequestSurfaceTarget(projectId: "p", repository: "o/r", number: 7)
        container.mutate { $0.openPullRequest(target) }
        #expect(closed.isEmpty)
        let id = container.panelState.surfaces[0].id
        container.mutate { _ = $0.close(id) }
        #expect(closed.map(\.id) == [id])
        var stack = ClosedPanelTabs()
        for s in closed { stack.remember(s, threadKey: "page:pull-requests") }
        let next = stack.popNext(threadExists: { $0.hasPrefix("page:") }, panel: { _ in container.panelState })
        #expect(next?.surface.id == id)
    }
}

/// 5258 #39315 (pullRequestMarkdown.logic.test.ts): GitHub `:alias:` emoji in prose, code left alone.
struct GitHubEmojiTests {
    @Test func expandsProseOnly() {
        #expect(GitHubEmoji.expand("Ship it :tada:") == "Ship it 🎉")
        #expect(GitHubEmoji.expand(":tada:tada:") == "🎉tada:")
        #expect(GitHubEmoji.expand("time 10:30:45 and :not_an_emoji:") == "time 10:30:45 and :not_an_emoji:")
        #expect(GitHubEmoji.expand(":+1: :-1:") == "👍 👎")
        #expect(GitHubEmoji.expandMarkdown("Done :rocket: `:rocket:`\n```\n:rocket:\n```\n    :rocket:") == "Done 🚀 `:rocket:`\n```\n:rocket:\n```\n    :rocket:")
    }
}
