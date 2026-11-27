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
        let composer = panel.composer.frame, project = panel.hero.frame, machine = panel.deviceRow.frame, starters = panel.starterRow.frame
        let gap = DitherPill.gap
        // The project and the machine share one row on the composer's top left.
        #expect(project.minX == composer.minX && project.maxY == composer.minY - gap)
        #expect(machine.minY == project.minY && machine.minX == project.minX + panel.hero.chipsWidth + DitherPill.spacing)
        #expect(panel.deviceRow.opensDown)
        // The starter sits one gap under it, centred under the composer. With a project chosen it offers only what
        // the project control doesn't: leaving the project.
        #expect(!panel.starterRow.isHidden && starters.minY == composer.maxY + gap)
        #expect(!panel.starterRow.withoutProject.isHidden && panel.starterRow.addProject.isHidden)
        let chip = panel.convert(panel.starterRow.withoutProject.frame, from: panel.starterRow)
        #expect(abs(chip.midX - composer.midX) <= 1)
        // Narrower than a thread's column, centred across the panel.
        #expect(composer.width <= RedesignTokens.Draft.width)
        #expect(abs(composer.midX - panel.bounds.midX) <= 1)

        // A draft without a project offers Add project instead, and the composer stays where it was.
        panel.hero.isScratch = true
        panel.layoutSubtreeIfNeeded()
        #expect(panel.starterRow.withoutProject.isHidden && !panel.starterRow.addProject.isHidden)
        #expect(panel.composer.frame == composer)
        // No scratch machine and a project: nothing to offer, so the row leaves (it fades out like the other pills).
        panel.hero.isScratch = false
        panel.hero.offersScratch = false
        panel.layoutSubtreeIfNeeded()
        #expect(panel.starterRow.isEmpty)
        #expect(panel.composer.frame == composer)
    }

    @Test func draftNoticesShareTheProjectRow() throws {
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous) }
        let (panel, window) = try panel(draft: true)
        defer { window.contentView = nil }
        panel.noticeBanner.apply(.init(variant: .neutral, icon: .info, title: "Cloning weather-cli", actions: ["Stop"]))
        panel.showsNoticeBanner = true
        panel.layoutSubtreeIfNeeded()
        let composer = panel.composer.frame, notice = panel.noticeBanner.frame, machine = panel.deviceRow.frame
        // Same row as the project and machine, after them, trailing-aligned to the composer's edge.
        #expect(!panel.noticeBanner.isHidden && notice.minY == panel.hero.frame.minY)
        #expect(notice.minX >= machine.maxX + DitherPill.spacing && notice.maxX == composer.maxX - DitherPill.inset)
    }

    @Test func draftNoticesShortenBeforeTheyWrap() {
        // Room for both at full width: each keeps its own.
        #expect(ThreadPanelView.draftNoticeWidths(natural: [200, 100], minimum: [80, 60], room: 400, spacing: 6) == [200, 100])
        // Short of room: each gives toward its narrowest form, and the pair fills the room exactly or less.
        let squeezed = ThreadPanelView.draftNoticeWidths(natural: [200, 100], minimum: [80, 60], room: 200, spacing: 6)
        #expect(squeezed.count == 2 && squeezed.allSatisfy { $0 > 0 })
        #expect(squeezed[0] >= 80 && squeezed[1] >= 60 && squeezed.reduce(0, +) + 6 <= 200)
        // The widest gives first: a short notice keeps its whole title while the long one shortens.
        #expect(ThreadPanelView.draftNoticeWidths(natural: [200, 100], minimum: [80, 60], room: 260, spacing: 6) == [154, 100])
        // Not even the narrowest forms fit: the last notice drops out rather than wrapping above the project.
        #expect(ThreadPanelView.draftNoticeWidths(natural: [200, 100], minimum: [80, 60], room: 100, spacing: 6) == [100, 0])
        #expect(ThreadPanelView.draftNoticeWidths(natural: [200], minimum: [80], room: 40, spacing: 6) == [0])
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
        let groupBottom = y + 100 + DitherPill.gap + DitherPill.height
        #expect(abs((groupTop + groupBottom) / 2 - 1000 * RedesignTokens.Draft.centre) <= 1)
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
        #expect(panel.starterRow.isHidden)
        #expect(!panel.deviceRow.opensDown)
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
