import AppKit
import Testing
import T3Protocol
@testable import Features

@MainActor
struct ComposerLayoutTransitionTests {
    @Test func submissionRestoresTheExpandedFrameBeforeShowingTheFooter() throws {
        let panel = try collapsedPanel()
        let composer = panel.composer
        composer.restingBlocked = { [weak composer] in composer?.isBusy == true }
        composer.isBusy = true
        composer.needsLayout = true
        panel.layoutSubtreeIfNeeded()
        #expect(!composer.isResting)
        #expect(composer.frame.height == composer.preferredHeight)
        #expect(composer.primary.frame.minY >= composer.placeholder.frame.maxY + 8)
        composer.isBusy = false
        panel.layoutSubtreeIfNeeded()
        #expect(!composer.isResting)
        #expect(composer.frame.height == composer.preferredHeight)
    }

    @Test func externalChromeRestoresTheFrameAfterOnlyTheComposerWasInvalidated() async throws {
        let panel = try collapsedPanel()
        let composer = panel.composer
        var blocked = false
        composer.restingBlocked = { blocked }
        blocked = true
        composer.needsLayout = true
        panel.layoutSubtreeIfNeeded()
        // External chrome may change while the parent's layout is already running.
        _ = await eventually {
            panel.layoutSubtreeIfNeeded()
            return composer.frame.height == composer.preferredHeight
        }
        #expect(!composer.isResting)
        #expect(composer.frame.height == composer.preferredHeight)
        #expect(composer.primary.frame.minY >= composer.placeholder.frame.maxY + 8)
        blocked = false
        composer.needsLayout = true
        panel.layoutSubtreeIfNeeded()
        #expect(!composer.isResting)
        #expect(composer.frame.height == composer.preferredHeight)
    }

    private func collapsedPanel() throws -> ThreadPanelView {
        let panel = ThreadPanelView(frame: NSRect(x: 0, y: 0, width: 1000, height: 780))
        let projection = try #require(try ThreadPreview.projection(titled: ThreadPreview.markdownThread))
        panel.setProjection(projection, projectTitle: "demo-repo", workspaceRoot: nil)
        ComposerFidelityTests.fill(panel.composer, model: "GPT-6.1-Sol")
        panel.composer.collapseOnScroll = true
        panel.composer.recordTimelineScroll(delta: -40, canScroll: true, towardEnd: false)
        panel.layoutSubtreeIfNeeded()
        #expect(panel.composer.isResting)
        #expect(panel.composer.frame.height == 50)
        return panel
    }
}
