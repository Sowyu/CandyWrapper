import AppKit
import Testing
import DesignSystem
import T3Protocol
import T3Store
@testable import Features

/// Redesign floats everything T3 docks on the composer as separate pills; other themes keep T3's attached dock.
@MainActor
struct ComposerDitherPillsTests {
    private func panel(dither: Bool) throws -> (ThreadPanelView, NSWindow) {
        var input = ThemeRuntime.input
        input.ditherLight = dither; input.ditherDark = dither
        ThemeRuntime.apply(input)
        let panel = ThreadPanelView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = panel
        panel.frame = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let projection = try JSONDecoder().decode(ThreadProjection.self, from: Data(#"{"thread":{"id":"t"},"runs":[],"updatedAt":"2026-10-22T00:00:00Z"}"#.utf8))
        panel.setProjection(projection, projectTitle: "Sandbox", workspaceRoot: nil)
        panel.stashBadge.count = 1
        panel.showsStashBadge = true
        panel.backgroundWorkBanner.apply(.init(variant: .neutral, icon: .info, title: "Running: Publish", actions: ["Stop"], priority: .activity))
        panel.showsBackgroundWork = true
        panel.goalBanner.apply(.init(variant: .neutral, icon: .target, title: "Goal: ship", actions: ["Clear"]))
        panel.showsGoal = true
        panel.layoutSubtreeIfNeeded()
        return (panel, window)
    }

    @Test func statusPillsFloatInARowAboveTheComposer() throws {
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous) }
        let (panel, window) = try panel(dither: true)
        defer { window.contentView = nil }
        let composer = panel.composer.frame, stash = panel.stashBadge.frame, work = panel.goalBanner.frame
        #expect(!panel.stashBadge.isHidden && !panel.goalBanner.isHidden)
        #expect(panel.stashBadge.placement == .floating && panel.goalBanner.placement == .floating)
        // One pill row, 8 above the composer: the work pill from the left, Stash at the right, apart.
        for pill in [stash, work] {
            #expect(pill.height == DitherPill.height)
            #expect(pill.maxY == composer.minY - DitherPill.gap)
        }
        // Inside the composer's corners: `DitherPill.inset` in from each side.
        #expect(work.minX == composer.minX + DitherPill.inset && stash.maxX == composer.maxX - DitherPill.inset)
        #expect(work.maxX < stash.minX)
    }

    @Test func pillsFloatAboveThePlanCard() throws {
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous) }
        let (panel, window) = try panel(dither: true)
        defer { window.contentView = nil }
        panel.tasksView.steps = [ThreadTaskStep(text: "Verify in the sandbox", status: "running")]
        panel.needsLayout = true
        panel.layoutSubtreeIfNeeded()
        let tasks = panel.tasksView.frame, stash = panel.stashBadge.frame
        // The plan card sits right on the composer; Stash floats above it, not between.
        #expect(!panel.tasksView.isHidden)
        #expect(tasks.maxY == panel.composer.frame.minY - DitherPill.gap)
        #expect(stash.maxY == tasks.minY - DitherPill.gap)
    }

    /// Capy's row under the composer: the background work becomes the waiting indicator at the right, left of the
    /// context ring, and leaves the pill row above.
    @Test func waitingIndicatorSitsUnderTheComposerAtTheRight() throws {
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous) }
        let (panel, window) = try panel(dither: true)
        defer { window.contentView = nil }
        panel.waitingIndicator.configure(title: "Waiting on subagent", waiting: true, header: "Waiting on subagent Fix it",
                                         links: [.init("Show subagent") {}], stop: .init("Stop") {})
        panel.composer.contextWindowMeter.usage = ThreadContextWindowUsage(used: 32_800, maximum: 400_000, automatically: true)
        panel.layoutSubtreeIfNeeded()
        let composer = panel.composer.frame, ring = panel.composer.contextWindowMeter.frame, waiting = panel.waitingIndicator.frame
        #expect(panel.backgroundWorkBanner.isHidden)
        #expect(!panel.waitingIndicator.isHidden && panel.waitingIndicator.showsLabel)
        #expect(panel.composer.contextWindowMeter.superview === panel && !panel.composer.contextWindowMeter.isHidden)
        for v in [ring, waiting] { #expect(v.minY == composer.maxY + DitherPill.gap && v.height == DitherPill.height) }
        #expect(ring.maxX == composer.maxX - DitherPill.inset)
        #expect(waiting.maxX == ring.minX - DitherPill.spacing)
        // Short label only: no task title.
        #expect(BackgroundWorkPresentation.shortTitle(.init(title: "Waiting on subagent Fix it", items: [
            .init(taskId: "a", kind: .subagent, label: "Fix it", childThreadId: ThreadId("c"))], waiting: true)) == "Waiting on subagent")
    }

    /// Capy's machine row takes the checkout and ref pills' place at the left of the same row, and nothing overlaps
    /// the waiting indicator and ring at a narrow width.
    @Test func deviceRowSitsLeftOfTheWaitingIndicatorWithoutOverlap() throws {
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous) }
        let (panel, window) = try panel(dither: true)
        defer { window.contentView = nil }
        panel.waitingIndicator.configure(title: "Waiting on subagent", waiting: true, header: "Waiting on subagent Fix it",
                                         links: [.init("Show subagent") {}], stop: .init("Stop") {})
        panel.composer.contextWindowMeter.usage = ThreadContextWindowUsage(used: 32_800, maximum: 400_000, automatically: true)
        panel.deviceRow.configure(machine: "A rather long machine name of a MacBook Pro", kind: "laptop", workspace: "Worktree", online: true)
        panel.showsDeviceRow = true
        for width: CGFloat in [1000, 420] {
            panel.frame.size.width = width
            panel.layoutSubtreeIfNeeded()
            let composer = panel.composer.frame, row = panel.deviceRow.frame, waiting = panel.waitingIndicator.frame
            #expect(!panel.deviceRow.isHidden && panel.contextStrip.isHidden)
            #expect(panel.deviceRow.subviews.contains { $0 is DitherPillSurface } && row.height == DitherPill.height)
            #expect(row.minY == composer.maxY + DitherPill.gap && row.minX == composer.minX + DitherPill.inset)
            #expect(row.maxX <= waiting.minX)
        }
    }

    @Test func composerStaysPutAsPillsComeAndGo() throws {
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous) }
        let (panel, window) = try panel(dither: true)
        defer { window.contentView = nil }
        let before = panel.composer.frame
        panel.showsStashBadge = false
        panel.showsBackgroundWork = false
        panel.layoutSubtreeIfNeeded()
        // The leaving pills fade out where they were; the composer stays.
        #expect(panel.composer.frame == before)
    }

    @Test func otherThemesKeepTheAttachedDock() throws {
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous) }
        let (panel, window) = try panel(dither: false)
        defer { window.contentView = nil }
        #expect(panel.stashBadge.placement == .attached && panel.backgroundWorkBanner.placement == .attached)
        // T3's tab and banner slide 17pt under the composer's top edge.
        #expect(panel.stashBadge.frame.maxY == panel.composer.frame.minY + ComposerBannerView.overlap)
    }
}
