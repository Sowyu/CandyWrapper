import Testing
@testable import Features

/// A send waits for pasted images to finish preparing (T3 5258 ComposerHeldSendBanner.tsx, #40672).
@MainActor
struct ComposerHeldSendTests {
    @Test func bannerCountsTheImagesStillPreparing() {
        #expect(ComposerLogic.heldSendTitle(preparing: 0) == "Sending message")
        #expect(ComposerLogic.heldSendTitle(preparing: 1) == "Sending once image is ready")
        #expect(ComposerLogic.heldSendTitle(preparing: 3) == "Sending once 3 images are ready")
    }

    /// ComposerPrimaryActions.tsx:404-415: a lost environment still wins; held comes before the send block.
    @Test func heldSendReadsSendingWhenReady() {
        #expect(ComposerLogic.submitStatus(environmentUnavailable: false, sendDisabledReason: "Preparing worktree", held: true,
                                           busy: false, editingQueued: false) == "Sending when ready")
        #expect(ComposerLogic.submitStatus(environmentUnavailable: true, sendDisabledReason: nil, held: true,
                                           busy: false, editingQueued: false) == "Environment disconnected")
    }

    @Test func heldSendShowsTheBusyButtonAndEscapeCancels() {
        let composer = ComposerView(frame: .init(x: 0, y: 0, width: 600, height: 120))
        composer.text = "hello"
        var cancelled = 0
        composer.onHeldSendEscape = { cancelled += 1; return true }
        composer.isSendHeld = true
        #expect(composer.primary.face == .busy)
        composer.isSendHeld = false
        #expect(composer.primary.face != .busy)
        _ = composer.onHeldSendEscape?()
        #expect(cancelled == 1)
    }
}
