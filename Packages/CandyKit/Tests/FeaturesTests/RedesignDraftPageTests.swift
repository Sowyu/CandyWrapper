import AppKit
import Testing
import DesignSystem
import T3Protocol
import T3Store
@testable import Features

/// Redesign's new-thread page and the rows around the composer, after Capy's: one group on the draft, one footer row
/// under a thread's composer, and a header pill that shows only what applies.
@MainActor
struct RedesignDraftPageTests {
    private func panel(draft: Bool) throws -> (ThreadPanelView, NSWindow) {
        var input = ThemeRuntime.input
        input.ditherLight = true; input.ditherDark = true
        ThemeRuntime.apply(input)
        let panel = ThreadPanelView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = panel
        panel.frame = NSRect(x: 0, y: 0, width: 1100, height: 800)
        if draft {
            panel.setDraft(projectTitle: "Sandbox")
        } else {
            let projection = try JSONDecoder().decode(ThreadProjection.self, from: Data(#"{"thread":{"id":"t"},"runs":[],"updatedAt":"2026-10-22T00:00:00Z"}"#.utf8))
            panel.setProjection(projection, projectTitle: "Sandbox", workspaceRoot: nil)
        }
        panel.deviceRow.configure(machine: "Sandbox Mac", kind: "laptop", workspace: "Local", online: true)
        panel.showsDeviceRow = true
        panel.layoutSubtreeIfNeeded()
        return (panel, window)
    }

    @Test func draftIsOneCentredGroup() throws {
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous) }
        let (panel, window) = try panel(draft: true)
        defer { window.contentView = nil }
        panel.hero.offersScratch = true
        panel.layoutSubtreeIfNeeded()
        let composer = panel.composer.frame, project = panel.hero.frame, machine = panel.deviceRow.frame
        let gap = DitherPill.gap
        // The project and the machine share one row on the composer's top left, quiet: no rim.
        #expect(project.minX == composer.minX && project.maxY == composer.minY - gap)
        #expect(machine.minY == project.minY && machine.minX == project.minX + panel.hero.chipsWidth + DitherPill.spacing)
        #expect(panel.deviceRow.opensDown && panel.deviceRow.quiet && panel.hero.projectChip.quiet)
        // Narrower than a thread's column, centred across the panel.
        #expect(composer.width <= RedesignTokens.Draft.width)
        #expect(abs(composer.midX - panel.bounds.midX) <= 1)
    }

    @Test func draftNoticesAreOneQuietControlAtTheRowsEnd() throws {
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous) }
        let (panel, window) = try panel(draft: true)
        defer { window.contentView = nil }
        panel.noticeBanner.apply(.init(variant: .neutral, icon: .download, title: "Server update available",
                                       actions: ["Copy relaunch command"], dismissible: true, shortTitle: "Server update"))
        panel.showsNoticeBanner = true
        panel.layoutSubtreeIfNeeded()
        let composer = panel.composer.frame, control = panel.draftNotices.frame, machine = panel.deviceRow.frame
        // Context then status: the control at the row's trailing end, the banner itself not drawn.
        #expect(!panel.draftNotices.isHidden && panel.noticeBanner.isHidden)
        #expect(control.minY == panel.hero.frame.minY && control.maxX == composer.maxX - DitherPill.inset && control.minX > machine.maxX)
        // One notice with room: its whole short title.
        #expect(panel.draftNotices.titled)
        // Two notices: one icon button with a count, never two chips.
        panel.lazyFallbackBanner.view.apply(.init(variant: .neutral, icon: .info, title: "Using Sonnet 5.5", dismissible: true))
        panel.fallbackKey = "weekly"
        panel.layoutSubtreeIfNeeded()
        #expect(panel.draftNotices.notices.count == 2 && !panel.draftNotices.titled)
        #expect(panel.draftNotices.frame.width < 2 * DitherPill.height)
    }

    @Test func aNoticeShowsItsTitleOnlyWhenItFitsWhole() {
        let notice = ComposerNoticeBannerView()
        notice.apply(.init(variant: .warning, icon: .triangleAlert, title: "Server update available", dismissible: true, shortTitle: "Server update"))
        let control = DitherNoticeControlView()
        control.update([notice])
        let wide = control.fit(room: 400)
        #expect(control.titled && wide > DitherPill.height)
        // Short of room: the icon button, never a cut title.
        #expect(control.fit(room: wide) == DitherPill.height && !control.titled)
    }

    @Test func queuedTilesFitWidePictures() {
        #expect(QueuedTile.gravity(16.0 / 9) == .resizeAspectFill)
        #expect(QueuedTile.gravity(1) == .resizeAspectFill)
        #expect(QueuedTile.gravity(3) == .resizeAspect)
        #expect(QueuedTile.gravity(0.3) == .resizeAspect)
    }

    @Test func draftGroupCentresOnCapysLine() {
        let y = ThreadPanelView.draftComposerY(top: 0, bottom: 1000, composer: 100)
        let groupTop = y - DitherPill.gap - DitherPill.height
        #expect(abs((groupTop + y + 100) / 2 - 1000 * RedesignTokens.Draft.centre) <= 1)
        // Never above the room's top.
        #expect(ThreadPanelView.draftComposerY(top: 40, bottom: 120, composer: 100) - DitherPill.gap - DitherPill.height >= 40)
    }


    @Test func footerRowHasOneRhythm() throws {
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous) }
        let (panel, window) = try panel(draft: false)
        defer { window.contentView = nil }
        let meter = panel.composer.contextWindowMeter
        meter.usage = ThreadContextWindowUsage(used: 32_800, maximum: 400_000, automatically: true)
        panel.layoutSubtreeIfNeeded()
        let composer = panel.composer.frame, machine = panel.deviceRow.frame, ring = meter.frame
        #expect(!panel.deviceRow.opensDown && !panel.deviceRow.quiet)
        // One row: same top, same height, flush with the composer's edges.
        #expect(machine.minY == ring.minY && machine.height == ring.height && machine.height == DitherPill.height)
        #expect(machine.minX == composer.minX + DitherPill.inset && ring.maxX == composer.maxX - DitherPill.inset)
        // The machine's glyph and text columns are the ring's and the figure's.
        let label = try #require(panel.deviceRow.subviews.compactMap { $0 as? LabelView }.first)
        #expect(label.frame.minX == DitherPill.textX && meter.figure.frame.minX == DitherPill.textX)
        #expect(label.frame.minY == meter.figure.frame.minY)
        #expect(label.font.pointSize == meter.figure.font.pointSize)
    }

    @Test func headerPillShowsOnlyWhatApplies() {
        let header = ThreadHeaderView()
        let pill = header.pill
        pill.cost = header.cost
        pill.toggles = header.toggles
        header.toggles.forEach { pill.addSubview($0) }
        pill.addSubview(header.cost)
        pill.showsVersionControl = true
        func width() -> CGFloat { pill.intrinsicContentSize.width }
        let bare = width()
        // No totals while the tree is clean.
        #expect(!pill.showsTotals)
        pill.totals.insertions = 59; pill.totals.deletions = 1
        #expect(pill.showsTotals && width() > bare)
        // A draft shows none, whatever the project's tree holds.
        pill.isDraft = true
        #expect(!pill.showsTotals && width() == bare)
        pill.isDraft = false
        pill.totals.insertions = 0; pill.totals.deletions = 0
        // "$0.00" is left out; a cent shows.
        var breakdown = ThreadCostEstimate.Breakdown()
        header.cost.breakdown = breakdown
        #expect(width() == bare)
        breakdown.outputUSD = 0.01
        header.cost.breakdown = breakdown
        #expect(width() > bare)
    }

    @Test func actionsTooltipNamesOnlyWhatTheMenuHolds() {
        let pill = DitherHeaderPillView()
        pill.menuSections[.editor] = { [MenuItem("Open in Zed")] }
        pill.menuSections[.scripts] = { [MenuItem("Run tests")] }
        pill.menuSections[.git] = { [MenuItem("Commit")] }
        pill.menuSections[.lineage] = { [] }
        #expect(pill.menuSummary(shown: [:]) == "Editor, scripts and git")
        #expect(pill.menuSummary(shown: ["scripts": false, "gitActions": false]) == "Editor")
        #expect(pill.menuSummary(shown: ["openIn": false, "scripts": false, "gitActions": false]) == "Thread actions")
    }
}
