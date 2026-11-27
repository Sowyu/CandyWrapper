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
    private func panel(draft: Bool, width: CGFloat = 1100, project: String = "Sandbox") throws -> (ThreadPanelView, NSWindow) {
        var input = ThemeRuntime.input
        input.ditherLight = true; input.ditherDark = true
        ThemeRuntime.apply(input)
        let panel = ThreadPanelView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = panel
        panel.frame = NSRect(x: 0, y: 0, width: width, height: 800)
        if draft {
            panel.setDraft(projectTitle: project)
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
        let gap = RedesignTokens.Draft.rowGap
        // The project and the machine share one row on the composer's top left, quiet: no rim.
        #expect(project.minX == composer.minX && project.maxY == composer.minY - gap)
        #expect(machine.minY == project.minY && machine.minX == project.minX + panel.hero.chipsWidth + RedesignTokens.Draft.rowSpacing)
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
        let groupTop = y - RedesignTokens.Draft.rowGap - DitherPill.height
        #expect(abs((groupTop + y + 100) / 2 - 1000 * RedesignTokens.Draft.centre) <= 1)
        // Never above the room's top.
        #expect(ThreadPanelView.draftComposerY(top: 40, bottom: 120, composer: 100) - RedesignTokens.Draft.rowGap - DitherPill.height >= 40)
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
        // Plain text on a quiet patch, like the new-thread page's row: not raised pills (the user, 2026-11-26).
        #expect(!panel.deviceRow.opensDown && panel.deviceRow.quiet)
        let patches = panel.subviews.compactMap { $0 as? DitherPillSurface }.filter { !$0.isHidden && $0.frame == ring }
        #expect(patches.count == 1 && patches.allSatisfy(\.quiet), "the ring sits on one quiet patch")
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

    private func addNotices(_ panel: ThreadPanelView, count: Int) {
        panel.noticeBanner.apply(.init(variant: .neutral, icon: .download, title: "Server update available",
                                       actions: ["Copy relaunch command"], dismissible: true, shortTitle: "Server update"))
        panel.showsNoticeBanner = true
        if count > 1 {
            panel.lazyFallbackBanner.view.apply(.init(variant: .neutral, icon: .info, title: "Using Sonnet 5.5", dismissible: true))
            panel.fallbackKey = "weekly"
        }
        panel.layoutSubtreeIfNeeded()
    }

    /// The user, 2026-11-26: "whys the stash so weird". On the new-thread page Stash is a quiet control in the context
    /// row, before the notices at its right end, never a raised pill on a row of its own.
    @Test(arguments: [0, 1, 2])
    func stashJoinsTheDraftRow(notices: Int) throws {
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous) }
        let (panel, window) = try panel(draft: true)
        defer { window.contentView = nil }
        panel.stashBadge.count = 2
        panel.showsStashBadge = true
        if notices > 0 { addNotices(panel, count: notices) }
        panel.layoutSubtreeIfNeeded()
        let stash = panel.stashBadge.frame, row = panel.hero.frame, composer = panel.composer.frame
        #expect(panel.stashBadge.quiet && !panel.stashBadge.isHidden)
        #expect(stash.minY == row.minY && stash.height == DitherPill.height, "one row with the project and machine")
        #expect(stash.minX >= panel.deviceRow.frame.maxX)
        if notices == 0 {
            #expect(stash.maxX == composer.maxX - DitherPill.inset)
        } else {
            #expect(stash.maxX + RedesignTokens.Draft.rowSpacing == panel.draftNotices.frame.minX, "Stash sits before the notices")
            #expect(panel.draftNotices.frame.maxX == composer.maxX - DitherPill.inset)
        }
        #expect(panel.stashBadge.showsTitle)
    }

    /// A long project name at 960pt: the notices shorten first, then Stash, and nothing overlaps or wraps.
    @Test func aLongProjectShortensTheNoticeThenStash() throws {
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous) }
        let (panel, window) = try panel(draft: true, width: 960, project: "candywrapper-native-redesign-composer-footer-integration")
        defer { window.contentView = nil }
        panel.stashBadge.count = 12
        panel.showsStashBadge = true
        addNotices(panel, count: 1)
        let machine = panel.deviceRow.frame, stash = panel.stashBadge.frame, notice = panel.draftNotices.frame
        #expect(stash.minY == machine.minY && notice.minY == machine.minY, "no row wraps")
        #expect(machine.maxX <= stash.minX && stash.maxX <= notice.minX)
        // The notice gave up its title before Stash did.
        #expect(!panel.draftNotices.titled || panel.stashBadge.showsTitle)
    }

    /// The user's 1.20.1 recording: opening the new-thread page from a thread slid the machine control and Stash
    /// over from their places in the thread. Every row control has its final frame after the page's first layout
    /// pass, with no animation on it.
    @Test func theDraftRowAppearsComposed() throws {
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous) }
        let (panel, window) = try panel(draft: false)
        defer { window.contentView = nil }
        panel.stashBadge.count = 2
        panel.showsStashBadge = true
        panel.layoutSubtreeIfNeeded()
        let inThread = panel.deviceRow.frame
        panel.setDraft(projectTitle: "Sandbox")
        panel.layoutSubtreeIfNeeded()
        let row = panel.hero.frame, machine = panel.deviceRow.frame
        #expect(machine != inThread)
        #expect(machine.minY == row.minY && machine.minX == row.minX + panel.hero.chipsWidth + RedesignTokens.Draft.rowSpacing)
        #expect(panel.stashBadge.frame.minY == row.minY)
        for view in [panel.deviceRow, panel.stashBadge] as [NSView] {
            #expect((view.layer?.animationKeys() ?? []).isEmpty, "\(type(of: view)) animates as the page shows")
            #expect(view.alphaValue == 1)
        }
        // And back to a thread: the machine is under the composer at once.
        let projection = try JSONDecoder().decode(ThreadProjection.self, from: Data(#"{"thread":{"id":"t2"},"runs":[],"updatedAt":"2026-10-22T00:00:00Z"}"#.utf8))
        panel.setDraft(projectTitle: nil)
        panel.setProjection(projection, projectTitle: "Sandbox", workspaceRoot: nil)
        panel.layoutSubtreeIfNeeded()
        #expect(panel.deviceRow.frame.minY > panel.composer.frame.maxY)
        #expect((panel.deviceRow.layer?.animationKeys() ?? []).isEmpty)
    }

    /// The new-thread page's row is bare text on the page's ground, at the row's smaller scale; under a thread's
    /// composer, where thread text passes behind it, the machine keeps its patch of ground.
    @Test func draftRowIsBareTextAtTheRowsScale() throws {
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous) }
        let (panel, window) = try panel(draft: true)
        defer { window.contentView = nil }
        func patches(_ view: NSView) -> [DitherPillSurface] { view.subviews.compactMap { $0 as? DitherPillSurface }.filter { !$0.isHidden } }
        #expect(patches(panel.hero.projectChip).isEmpty && patches(panel.deviceRow).isEmpty)
        let label = try #require(panel.deviceRow.subviews.compactMap { $0 as? LabelView }.first)
        #expect(label.font.pointSize == RedesignTokens.Draft.rowText)
        let projection = try ThreadPreview.projection(titled: ThreadPreview.markdownThread)
        panel.setDraft(projectTitle: nil)
        panel.setProjection(projection, projectTitle: "Sandbox", workspaceRoot: nil)
        panel.layoutSubtreeIfNeeded()
        #expect(patches(panel.deviceRow).count == 1, "the thread's row keeps its patch")
    }
}
