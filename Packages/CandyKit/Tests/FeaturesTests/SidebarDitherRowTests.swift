import AppKit
import Testing
import DesignSystem
import T3Protocol
import T3Store
@testable import Features

/// Dither rows: the Waiting dot grid, sections that follow the list state, and patches that keep rows in their section.
@MainActor
struct SidebarDitherRowTests {
    @Test func waitingRowShowsTheDotGridBesideItsLabel() throws {
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous) }
        var dither = previous
        dither.ditherLight = true; dither.ditherDark = true
        ThemeRuntime.apply(dither)
        let content = SidebarContentView()
        content.now = { SidebarPreview.referenceNow }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 255, height: 780), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = content
        content.frame = NSRect(x: 0, y: 0, width: 255, height: 780)
        content.setSnapshot(SidebarPreview.snapshot(projects: [SidebarPreview.project("p1", "demo-repo")], threads: [
            SidebarPreview.thread("q1", "Waits on a child", project: "p1", kind: .working, minutesAgo: 3, extra: ["blockedOnThreadWait": true]),
        ]), animated: false)
        content.layoutSubtreeIfNeeded()
        content.list.layoutSubtreeIfNeeded()
        let card = try #require(content.list.rowView("thread:q1") as? SidebarCardRowView)
        #expect(card.row?.topStatus == .waiting)
        card.layoutSubtreeIfNeeded()
        let grid = try #require(card.subviews.compactMap { $0 as? DotGridSpinnerView }.first)
        #expect(!grid.isHidden)
        let label = try #require(card.subviews.compactMap { $0 as? LabelView }.first { $0.text == "Waiting" })
        #expect(grid.frame.maxX <= label.frame.minX)
        window.contentView = nil
    }

    @Test func projectSectionsFollowTheListStateAndSurvivePatches() throws {
        let now = Int64(SidebarPreview.referenceNow.timeIntervalSince1970 * 1000)
        func snapshot(_ title: String) -> ShellSnapshot {
            SidebarPreview.snapshot(projects: [SidebarPreview.project("p1", "demo-repo")], threads: [
                SidebarPreview.thread("t1", title, project: "p1", kind: .done, minutesAgo: 5),
                SidebarPreview.thread("t2", "Other", project: "p1", kind: .done, minutesAgo: 9),
            ])
        }
        // A light standard theme beside dark Dither: the light list has no sections.
        let flat = SidebarListBuilder.items(snapshot: snapshot("First"), state: SidebarListState(), nowMs: now)
        #expect(!flat.contains { if case .projectHeader = $0 { true } else { false } })
        var state = SidebarListState()
        state.dither = true
        let cache = SidebarListCache()
        let items = SidebarListBuilder.items(snapshot: snapshot("First"), state: state, nowMs: now, cache: cache)
        #expect(items.contains { if case .projectHeader = $0 { true } else { false } })
        // A thread changed in place patches its row, which must stay under the header.
        let patch = try #require(cache.patch(snapshot: snapshot("Renamed"), state: state, nowMs: now))
        let row = try #require(patch.compactMap { if case .row(let r) = $0.item, r.id.rawValue.hasSuffix("t1") { r } else { nil } }.first)
        #expect(row.title == "Renamed" && row.inProjectSection && row.dither)
    }
}
