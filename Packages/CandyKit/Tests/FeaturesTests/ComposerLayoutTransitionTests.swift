import AppKit
import Testing
import DesignSystem
import T3Protocol
@testable import Features

@MainActor
struct ComposerLayoutTransitionTests {
    @Test func submissionRestoresTheExpandedFrameBeforeShowingTheFooter() throws {
        let original = ThemeRuntime.input
        var glass = original; glass.glassLight = true; glass.glassDark = true
        ThemeRuntime.apply(glass)
        defer { ThemeRuntime.apply(original) }
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
        let original = ThemeRuntime.input
        var glass = original; glass.glassLight = true; glass.glassDark = true
        let panel = try withTheme(glass) { try collapsedPanel() }
        let composer = panel.composer
        var blocked = false
        composer.restingBlocked = { blocked }
        blocked = true
        withTheme(glass) {
            composer.needsLayout = true
            panel.layoutSubtreeIfNeeded()
        }
        // External chrome may change while the parent's layout is already running.
        _ = await eventually {
            withTheme(glass) {
                panel.layoutSubtreeIfNeeded()
                return composer.frame.height == composer.preferredHeight
            }
        }
        withTheme(glass) {
            #expect(!composer.isResting)
            #expect(composer.frame.height == composer.preferredHeight)
            #expect(composer.primary.frame.minY >= composer.placeholder.frame.maxY + 8)
            blocked = false
            composer.needsLayout = true
            panel.layoutSubtreeIfNeeded()
            #expect(!composer.isResting)
            #expect(composer.frame.height == composer.preferredHeight)
        }
    }

    /// Screen pass 2026-11-20, item 7: T3 renders Previous, the submit pill, then Stop (ComposerPrimaryActions.tsx:332-361).
    @Test func questionFooterPutsStopAfterTheSubmitPill() throws {
        let panel = ThreadPanelView(frame: NSRect(x: 0, y: 0, width: 1000, height: 780))
        let composer = panel.composer
        composer.runState = ComposerLogic.RunState(running: true)
        composer.pending = .question(.init(label: "Submit answers", compactLabel: "Submit", enabled: true, showsPrevious: true,
                                           responding: false, showsAttach: false))
        panel.layoutSubtreeIfNeeded()
        composer.layoutSubtreeIfNeeded()
        let previous = composer.previousFull.isHidden ? composer.previousCompact : composer.previousFull
        #expect(!composer.primary.isHidden && !composer.questionPill.isHidden && !previous.isHidden)
        #expect(previous.frame.maxX <= composer.questionPill.frame.minX)
        #expect(composer.questionPill.frame.maxX <= composer.primary.frame.minX, "Stop sits right of the pill")
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
