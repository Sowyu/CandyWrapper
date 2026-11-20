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

    /// Screen pass 2026-11-20, item 3: after `/clear`, archiving the thread landed on the new-thread page with the
    /// "fresh session" banner still drawn where the docked composer had been.
    @Test func freshSessionBannerHidesWhenTheRouteLeavesTheThread() throws {
        let original = ThemeRuntime.input
        var plain = original
        plain.ditherLight = false; plain.ditherDark = false; plain.glassLight = false; plain.glassDark = false
        ThemeRuntime.apply(plain)
        defer { ThemeRuntime.apply(original) }
        let panel = ThreadPanelView(frame: NSRect(x: 0, y: 0, width: 1000, height: 780))
        let projection = try #require(try ThreadPreview.projection(titled: ThreadPreview.markdownThread))
        panel.setProjection(projection, projectTitle: "demo-repo", workspaceRoot: nil)
        panel.lazyFreshSessionBanner.view.apply(.init(variant: .neutral, icon: .eraser, title: "Your next message starts a fresh session"))
        panel.freshSessionKey = "thread-key"
        panel.layoutSubtreeIfNeeded()
        let banner = try #require(panel.lazyFreshSessionBanner.loaded)
        #expect(!banner.isHidden && banner.superview != nil, "the banner shows over the docked composer")
        panel.setDraft(projectTitle: "demo-repo", isScratch: false)
        panel.freshSessionKey = nil
        panel.layoutSubtreeIfNeeded()
        #expect(banner.isHidden || banner.superview == nil, "no banner on the new-thread page")
    }

    /// Screen pass 2026-11-20, item 15: a file chip's pierre icon keeps its file-type color, gray for a text file
    /// (`PierreEntryIcon`, contextChipParts.tsx:338), instead of the chip's blue ink.
    @Test func fileChipIconKeepsItsFileTypeColor() throws {
        let look = ComposerChipLook(kind: .file(name: "todo.txt"), label: "todo.txt")
        let (icon, iconColor) = look.icon
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 120, pixelsHigh: 24, bitsPerSample: 8, samplesPerPixel: 4,
                                                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            ComposerChipAttachment.draw(look: look, label: look.label, icon: icon, iconColor: iconColor,
                                        in: CGRect(x: 0, y: 0, width: 120, height: 24), ctx: context.cgContext)
        }
        context.flushGraphics()
        // The most opaque pixel of the icon, in the chip's first 16 points.
        var best: NSColor?
        for x in 0..<16 { for y in 0..<24 {
            if let c = rep.colorAt(x: x, y: y), c.alphaComponent > (best?.alphaComponent ?? 0.3) { best = c }
        } }
        let ink = try #require(best?.usingColorSpace(.deviceRGB))
        #expect(ink.blueComponent - ink.redComponent < 0.08, "the text file icon is gray, not blue: \(ink)")
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
