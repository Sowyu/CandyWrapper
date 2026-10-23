import AppKit
import Testing
import DesignSystem
import T3Protocol
import T3Store
@testable import Features

/// Dither rows: the Waiting dot grid without its word, sections that follow the list state, and patches that keep rows in their section.
@MainActor
struct SidebarDitherRowTests {
    @Test func waitingRowShowsTheDotGridWithoutItsWord() throws {
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
        // The grid stands in for the word, at the right of the title line.
        let labels = card.subviews.compactMap { $0 as? LabelView }
        #expect(!labels.contains { $0.text == "Waiting" })
        let title = try #require(labels.first { $0.text == "Waits on a child" })
        #expect(grid.frame.minX >= title.frame.maxX)
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

    @Test func threadMenuLeadsWithSettleAndSnoozeAndEndsWithTheKeyedActions() {
        var state = ThreadActionMenu.State()
        state.branch = "main"
        let built = DitherThreadMenu.items(ThreadActionMenu.items(state), presets: [], openInNewTab: true) { _ in }
        let titles = built.items.map { if case .separator = $0.kind { "-" } else { $0.title } }
        #expect(Array(titles.prefix(4)) == ["Settle", "Snooze", "-", "Open in new tab"])
        #expect(Array(titles.suffix(4)) == ["-", "Mark as unread", "Archive", "Delete"])
        #expect(built.items.allSatisfy { if case .separator = $0.kind { true } else { $0.icon != nil } })
        #expect(built.items.last?.isDestructive == true)
        for (key, title) in [("s", "Settle"), ("z", "Snooze"), ("u", "Mark as unread"), ("a", "Archive"), ("d", "Delete")] {
            #expect(built.keys[key].map { built.items[$0].title } == title)
        }
    }

    @Test func hoveredRowShowsSettleSnoozeAndMore() throws {
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
            SidebarPreview.thread("d1", "Finished work", project: "p1", kind: .done, minutesAgo: 3),
        ]), animated: false)
        content.layoutSubtreeIfNeeded()
        let card = try #require(content.list.rowView("thread:d1") as? SidebarCardRowView)
        card.isKeyboardFocused = true
        card.refresh()
        card.layoutSubtreeIfNeeded()
        let shown = card.subviews.compactMap { $0 as? RowActionButton }.filter { !$0.isHidden }
        #expect(shown.map(\.toolTip) == ["Settle thread", "Snooze thread", "More actions"])
        // In order without overlap; Settle carries its word, so it is wider than the icon-only buttons, which match.
        #expect(zip(shown, shown.dropFirst()).allSatisfy { $0.frame.maxX <= $1.frame.minX })
        #expect(shown[0].frame.width > shown[1].frame.width && shown[1].frame.width == shown[2].frame.width)
        window.contentView = nil
    }
}
