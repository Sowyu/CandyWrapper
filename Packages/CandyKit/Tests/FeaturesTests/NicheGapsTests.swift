import AppKit
import Testing
import DesignSystem
@testable import Features

/// The composer and thread gaps from the niche list, part 2: send-block reasons, the branch change
/// notice, the empty thread line, the environment-down send, notice details and dismiss labels.
@MainActor
struct NicheGapsTests {
    @Test func sendBlockReasonsFollowT3Order() {
        // ChatView.tsx:11618-11632: rewinding, then loading, then the worktree, then the clone.
        #expect(ComposerLogic.SendBlock().reason == nil)
        #expect(ComposerLogic.SendBlock(rewinding: true, detailLoading: true, preparingWorktree: true, projectClone: "Cloning repository").reason == "Rewinding conversation")
        #expect(ComposerLogic.SendBlock(detailLoading: true, preparingWorktree: true).reason == "Messages loading")
        #expect(ComposerLogic.SendBlock(preparingWorktree: true, projectClone: "Repository not cloned").reason == "Preparing worktree")
        #expect(ComposerLogic.SendBlock(projectClone: "Repository not cloned").reason == "Repository not cloned")
        // ChatView.tsx:2527-2533.
        #expect(ComposerLogic.projectCloneSendBlockReason(running: nil, done: false) == nil)
        #expect(ComposerLogic.projectCloneSendBlockReason(running: true, done: false) == "Cloning repository")
        #expect(ComposerLogic.projectCloneSendBlockReason(running: false, done: true) == nil)
        #expect(ComposerLogic.projectCloneSendBlockReason(running: false, done: false) == "Repository not cloned")
        // ChatView.tsx:4024-4027: a running setup blocks until the agent stage is done; no snapshot falls back to the run.
        #expect(ComposerLogic.worktreeSetupBlocksSend(phase: "running", agentDone: false, runPreparing: false))
        #expect(!ComposerLogic.worktreeSetupBlocksSend(phase: "running", agentDone: true, runPreparing: true))
        #expect(!ComposerLogic.worktreeSetupBlocksSend(phase: "done", agentDone: false, runPreparing: true))
        #expect(ComposerLogic.worktreeSetupBlocksSend(phase: nil, agentDone: false, runPreparing: true))
    }

    @Test func submitStatusPutsTheEnvironmentFirst() {
        // ComposerPrimaryActions.tsx:292-304.
        #expect(ComposerLogic.submitStatus(environmentUnavailable: true, sendDisabledReason: "Messages loading", busy: true, editingQueued: false) == "Environment disconnected")
        #expect(ComposerLogic.submitStatus(environmentUnavailable: false, sendDisabledReason: "Messages loading", busy: true, editingQueued: false) == "Messages loading")
        #expect(ComposerLogic.submitStatus(environmentUnavailable: false, sendDisabledReason: nil, busy: true, editingQueued: true) == "Updating queued message")
        #expect(ComposerLogic.submitStatus(environmentUnavailable: false, sendDisabledReason: nil, busy: true, editingQueued: false) == "Submitting message")
        #expect(ComposerLogic.submitStatus(environmentUnavailable: false, sendDisabledReason: nil, busy: false, editingQueued: false) == nil)
        #expect(ComposerLogic.submitStatus(environmentUnavailable: true, providerUnavailable: true, sendDisabledReason: nil, busy: false,
                                           editingQueued: false) == "Enable a provider to send a message")
    }

    @Test func environmentDownStillSendsOnEnter() {
        // The button is disabled with T3's label, but Enter reaches onSend so the controller can toast.
        let composer = ComposerView()
        composer.frame = NSRect(x: 0, y: 0, width: 600, height: 120)
        composer.text = "hello"
        composer.environmentUnavailable = true
        var sent: String?
        composer.onSend = { text, _, _ in sent = text }
        composer.submit()
        #expect(sent == "hello")
        // A real block stops it.
        sent = nil
        composer.environmentUnavailable = false
        composer.sendDisabledReason = "Messages loading"
        composer.submit()
        #expect(sent == nil)
    }

    @Test func branchMismatch() {
        // BranchToolbar.logic.ts:250-264.
        let m = BranchToolbarLogic.localCheckoutBranchMismatch(mode: .local, worktreePath: nil, threadBranch: "feature-x", currentGitBranch: "main")
        #expect(m == .init(threadBranch: "feature-x", currentBranch: "main"))
        #expect(m?.key(threadId: "t1") == "t1:feature-x:main")
        #expect(m?.tooltip == "This thread last ran on feature-x. Sending will continue on main.")
        #expect(BranchToolbarLogic.localCheckoutBranchMismatch(mode: .worktree, worktreePath: nil, threadBranch: "a", currentGitBranch: "b") == nil)
        #expect(BranchToolbarLogic.localCheckoutBranchMismatch(mode: .local, worktreePath: "/wt", threadBranch: "a", currentGitBranch: "b") == nil)
        #expect(BranchToolbarLogic.localCheckoutBranchMismatch(mode: .local, worktreePath: nil, threadBranch: "a", currentGitBranch: "a") == nil)
        #expect(BranchToolbarLogic.localCheckoutBranchMismatch(mode: .local, worktreePath: nil, threadBranch: "", currentGitBranch: "a") == nil)
        #expect(BranchToolbarLogic.localCheckoutBranchMismatch(mode: .local, worktreePath: nil, threadBranch: "a", currentGitBranch: nil) == nil)
        // ChatView.logic.ts:926-936: only with draft content, then held until dismissed.
        #expect(!BranchToolbarLogic.showsBranchMismatchBanner(hasMismatch: true, dismissed: false, composerHasContent: false, wasShown: false))
        #expect(BranchToolbarLogic.showsBranchMismatchBanner(hasMismatch: true, dismissed: false, composerHasContent: true, wasShown: false))
        #expect(BranchToolbarLogic.showsBranchMismatchBanner(hasMismatch: true, dismissed: false, composerHasContent: false, wasShown: true))
        #expect(!BranchToolbarLogic.showsBranchMismatchBanner(hasMismatch: true, dismissed: true, composerHasContent: true, wasShown: true))
        #expect(!BranchToolbarLogic.showsBranchMismatchBanner(hasMismatch: false, dismissed: false, composerHasContent: true, wasShown: true))
    }

    @Test func dismissLabels() {
        // ComposerBannerStack.tsx:374: "Dismiss warning" unless the item names its own.
        let plain = ComposerNoticeBannerView.Content(variant: .neutral, icon: .info, title: "T", dismissible: true)
        #expect(plain.dismissible && plain.resolvedDismissLabel == "Dismiss warning")
        let none = ComposerNoticeBannerView.Content(variant: .neutral, icon: .info, title: "T")
        #expect(!none.dismissible)
        let v = ComposerNoticeBannerView()
        v.apply(.init(variant: .neutral, icon: .gitBranch, title: "feature-x", actions: ["Restore branch"],
                      dismissLabel: "Dismiss branch change notice", titlePrefix: "Branch changed \u{2014} was", titleCode: true))
        #expect(v.dismissControl?.accessibilityLabel() == "Dismiss branch change notice")
        let failed = ComposerServerUpdateNotice(status: .failed("boom")).content
        #expect(failed.dismissible && failed.dismissLabel == "Dismiss update notice")
    }

    @Test func noticeDetailsButtonOnlyWhenCut() {
        let v = ComposerNoticeBannerView()
        v.apply(.init(variant: .neutral, icon: .download, title: "Cloning repo", description: "Receiving objects"))
        v.frame = NSRect(x: 0, y: 0, width: 600, height: ComposerNoticeBannerView.height)
        v.layoutSubtreeIfNeeded()
        #expect(v.detailsButton.isHidden)
        v.apply(.init(variant: .neutral, icon: .download, title: "Cloning repo",
                      description: String(repeating: "Receiving objects and resolving deltas ", count: 8)))
        v.layoutSubtreeIfNeeded()
        #expect(!v.detailsButton.isHidden)
        #expect(v.detailsButton.accessibilityLabel() == "Show notice details")
        #expect(v.detailsButton.frame.maxX <= v.bounds.width - 4)
        // A compact banner under 400pt hides its description: the button stands in for it.
        v.apply(.init(variant: .neutral, icon: .download, title: "Cloning repo", description: "Receiving", compact: true))
        v.frame.size.width = 360
        v.layoutSubtreeIfNeeded()
        #expect(!v.detailsButton.isHidden)
        #expect(v.titleDetailsButton.isHidden)
        // 060ac670a9: a cut title gets "Show title details" right after it.
        v.apply(.init(variant: .neutral, icon: .terminal, title: "Running: /usr/bin/zsh -lc " + String(repeating: "make test ", count: 30)))
        v.frame.size.width = 360
        v.layoutSubtreeIfNeeded()
        #expect(!v.titleDetailsButton.isHidden)
        #expect(v.titleDetailsButton.accessibilityLabel() == "Show title details")
        #expect(v.titleDetailsButton.frame.maxX <= v.bounds.width - 4)
        let popup = NoticeDetailsPopupView(text: "Receiving")
        #expect(popup.accessibilityLabel() == "Notice details")
        #expect(popup.popupSize.width <= 480)
    }

    /// Writes the cut notice with its details button, the details popup and the branch notice to
    /// /tmp/candywrapper-fidelity/nichea for a look (no reference: T3 shows them only in live states).
    @Test func noticeRenders() throws {
        let out = URL(fileURLWithPath: "/tmp/candywrapper-fidelity/nichea")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let cut = ComposerNoticeBannerView()
        cut.apply(.init(variant: .error, icon: .download, title: "Failed to clone repo",
                        description: "fatal: could not read Username for 'https://github.com': terminal prompts disabled, and more",
                        actions: ["Remove project", "Retry"]))
        let branch = ComposerNoticeBannerView()
        branch.apply(.init(variant: .neutral, icon: .gitBranch, title: "feature/a-rather-long-branch-name-for-the-notice", actions: ["Restore branch"],
                           dismissLabel: "Dismiss branch change notice", titlePrefix: "Branch changed \u{2014} was", titleCode: true))
        let popup = NoticeDetailsPopupView(text: "fatal: could not read Username for 'https://github.com': terminal prompts disabled, and more")
        for dark in [false, true] {
            for (name, view, size) in [("cut", cut as NSView, NSSize(width: 560, height: 51)), ("branch", branch, NSSize(width: 460, height: 51)),
                                       ("popup", popup, popup.popupSize)] {
                let canvas = SidebarSearchFidelityTests.Canvas(frame: .zero)
                view.frame = NSRect(x: 8, y: 8, width: size.width, height: size.height)
                canvas.addSubview(view)
                let image = Snapshot.image(of: canvas, size: NSSize(width: size.width + 16, height: size.height + 16), scale: 2, dark: dark)
                try Snapshot.writePNG(image, to: out.appendingPathComponent("\(name).\(dark ? "dark" : "light").png"))
                view.removeFromSuperview()
            }
        }
        #expect(!cut.detailsButton.isHidden)
    }

    @Test func emptyServerThreadLine() {
        let timeline = TimelineView()
        timeline.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        timeline.layoutSubtreeIfNeeded()
        let line = { timeline.subviews.compactMap { $0 as? LabelView }.first { $0.text == "Send a message to start the conversation." } }
        // Drafts and loading threads hold no label at all.
        #expect(line() == nil)
        timeline.allowsEmptyPlaceholder = true
        let label = try? #require(line())
        #expect(label?.isHidden == false)
        #expect(abs((label?.frame.midY ?? 0) - 300) < 1)
        timeline.allowsEmptyPlaceholder = false
        #expect(label?.isHidden == true)
    }
}
