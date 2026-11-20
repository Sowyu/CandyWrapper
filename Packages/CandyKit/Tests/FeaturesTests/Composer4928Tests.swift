import AppKit
import Testing
@testable import Features
import T3Protocol
import T3Store

/// Composer behavior from T3 Nightly 4928 (docs/research/nightly-diff-4928.md, sections 2.3 to 2.6).
@MainActor
struct Composer4928Tests {
    /// #31283: Send now says why a queued message could not send.
    @Test func sendNowFailureShowsAToast() {
        #expect(ComposerFeedback.surface(for: .queueSendNow("Run ended")) == .toast(.error, title: "Could not send queued message", description: "Run ended"))
        #expect(ComposerFeedback.surface(for: .queueSendNow(nil)) == .toast(.error, title: "Could not send queued message", description: "An error occurred."))
        #expect(ComposerFeedback.surface(for: .queueCommand) == .none)
    }

    /// #33092: a plain send goes while uploads run; an approval redirect and interrupted files still block.
    @Test func uploadsBlockOnlyApprovalRedirects() {
        var a = ComposerAttachment(kind: .image, name: "a.png", mimeType: "image/png", sizeBytes: 10,
                                   fileURL: URL(fileURLWithPath: "/tmp/a.png"), status: .uploading(0.5), environmentId: "e")
        #expect(ComposerAttachmentRules.sendBlockReason([a], redirectsApproval: false) == nil)
        #expect(ComposerAttachmentRules.sendBlockReason([a], redirectsApproval: true) == "Attachment still uploading")
        a.needsReattach = true
        #expect(ComposerAttachmentRules.sendBlockReason([a], redirectsApproval: false) == "Attach the interrupted file again or remove it")
    }

    /// #30325: `/clear` replaces the provider's command at the prompt's start when the server honors `freshContext`.
    @Test func clearCommandArmsAFreshSession() {
        let commands = [ServerProviderSlashCommand(name: "clear", description: "Provider clear")]
        func labels(_ trigger: ComposerTrigger, fresh: Bool) -> [String] {
            ComposerMenus.slashItems(trigger: trigger, provider: "claudeAgent", commands: commands, skills: [], showSkills: false,
                                     compactAvailable: false, freshSessionAvailable: fresh).map(\.id)
        }
        let start = ComposerTrigger(kind: .slashCommand, query: "cl", rangeStart: 0, rangeEnd: 3)
        #expect(labels(start, fresh: true) == ["slash:clear"])
        #expect(labels(start, fresh: false) == ["provider-slash-command:claudeAgent:clear"])
        #expect(labels(ComposerTrigger(kind: .slashCommand, query: "cl", rangeStart: 4, rangeEnd: 7), fresh: true).isEmpty)
        #expect(ComposerMenus.isClearCommand("  /CLEAR  "))
        #expect(!ComposerMenus.isClearCommand("/clear now"))
    }

    /// #27280: pasted CRLF keeps its blank lines.
    @Test func pastedLineBreaksNormalize() {
        #expect(ComposerPasteboard.normalizedLineBreaks("a\r\n\r\nb\rc") == "a\n\nb\nc")
    }

    /// #28459: the strip names a started thread's worktree folder.
    @Test func lockedWorktreeShowsItsFolder() {
        #expect(BranchToolbarLogic.lockedWorkspaceLabel("/Users/me/.t3/worktrees/app/t3-1234/", mode: .worktree) == "t3-1234")
        #expect(BranchToolbarLogic.lockedWorkspaceLabel("/", mode: .worktree) == "Worktree")
        #expect(BranchToolbarLogic.lockedWorkspaceLabel(nil, mode: .local) == "Local checkout")
    }

    /// #24861: the provider status banner ends its message with the setup link and an outline Refresh.
    @Test func providerBannerHasRefresh() {
        let view = ThreadErrorBannerView()
        view.banner = ThreadErrorState.Banner(message: "Claude is not signed in.", variant: .error, title: "Claude is unauthenticated",
                                              info: true, setupLink: true)
        let width = view.fittingWidth(max: 600)
        view.frame = NSRect(x: 0, y: 0, width: width, height: view.height(forWidth: width))
        view.layoutSubtreeIfNeeded()
        #expect(!view.refresh.isHidden)
        #expect(view.setup.frame.maxX + 12 <= view.refresh.frame.minX + 0.5)
        view.refreshing = true
        #expect(view.refresh.title == "Refreshing..." && !view.refresh.isEnabled)
        view.banner = ThreadErrorState.Banner(message: "Boom", variant: .error)
        #expect(view.refresh.isHidden)
    }
}
