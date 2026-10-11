import AppKit
import Testing
import DesignSystem
import T3Protocol
import T3Store
@testable import Features

/// Behaviour of the virtualized timeline: recycling, follow-the-end, anchoring and expand state.
@MainActor
struct ThreadTimelineTests {
    /// Rows of every recorded thread, ids made unique, every fold open: a long timeline.
    static func manyItems(copies: Int = 3) throws -> [TimelineItem] {
        var out: [TimelineItem] = []
        for copy in 0..<copies {
            for p in try ThreadPreview.projections() {
                var input = TimelineRowsInput(projection: p)
                input.expandedRunIds = Set(p.runs.map(\.id))
                for var row in TimelineRows.derive(input) {
                    row.id = "\(copy):\(p.thread.id.rawValue):\(row.id)"
                    out.append(TimelineItem(row: row))
                }
            }
        }
        return out
    }

    static func timeline(_ items: [TimelineItem]) -> TimelineView {
        let t = TimelineView(frame: NSRect(x: 0, y: 0, width: 844, height: 728))
        t.layoutSubtreeIfNeeded()
        t.setItems(items)
        return t
    }

    static func viewport(_ t: TimelineView) -> NSRect { t.scrollView.contentView.bounds }

    @Test func onlyRowsNearTheViewportHaveViews() throws {
        let items = try Self.manyItems()
        #expect(items.count > 100)
        let t = Self.timeline(items)
        #expect(t.liveViewCount < 40)
        let created = t.createdRowViews
        // Scrolling through recycles instead of making new views.
        for f in stride(from: 0.0, through: 1.0, by: 0.1) { t.scroll(toFraction: f) }
        #expect(t.liveViewCount < 40)
        #expect(t.createdRowViews < created + items.count / 2)
    }

    @Test func opensAtTheEndAndFollowsGrowth() throws {
        let items = try Self.manyItems()
        let t = Self.timeline(Array(items.prefix(80)))
        #expect(t.followsEnd)
        #expect(abs(Self.viewport(t).maxY - t.documentHeight) < 1)
        t.setItems(Array(items.prefix(120)))
        #expect(abs(Self.viewport(t).maxY - t.documentHeight) < 1)
        #expect(!t.isPillVisible)
    }

    /// A terminal drawer opening with a thread switch shrinks the viewport; the newest row stays in view.
    @Test func staysAtTheEndWhenTheViewportShrinks() throws {
        let items = try Self.manyItems()
        let t = Self.timeline(Array(items.prefix(80)))
        #expect(t.followsEnd)
        t.setFrameSize(NSSize(width: t.frame.width, height: t.frame.height - 280))
        t.layoutSubtreeIfNeeded()
        #expect(t.followsEnd)
        #expect(abs(Self.viewport(t).maxY - t.documentHeight) < 1)
        #expect(!t.isPillVisible)
    }

    @Test func prependingKeepsTheVisibleRowInPlace() throws {
        let items = try Self.manyItems()
        let t = Self.timeline(Array(items.suffix(150)))
        t.scroll(toFraction: 0.4)
        #expect(!t.followsEnd)
        let first = Self.viewport(t).minY
        let anchor = try #require(t.items.first { t.view(forRow: $0.id).map { $0.frame.maxY > first } ?? false })
        let before = t.view(forRow: anchor.id)!.frame.minY - Self.viewport(t).minY
        t.setItems(Array(items.suffix(200)))
        let after = try #require(t.view(forRow: anchor.id)).frame.minY - Self.viewport(t).minY
        #expect(abs(before - after) <= 0.5)
    }

    @Test func nearingTheTopAsksForOlderRows() throws {
        let t = Self.timeline(try Self.manyItems())
        var calls = 0
        t.onNearTop = { calls += 1 }
        t.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 100))
        t.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 50))
        #expect(calls == 1)
        #expect(!t.followsEnd)
    }

    /// A thread switch keeps the last thread's rows until the new thread's first projection, then
    /// swaps in one pass that starts at the end (T3's `resolveThreadSwitchTimeline`). Clearing first
    /// painted an empty window between the two threads.
    @Test func switchingThreadsNeverPaintsAnEmptyTimeline() throws {
        let all = try ThreadPreview.projections().filter { !TimelineRows.derive(TimelineRowsInput(projection: $0)).isEmpty }
        let a = try #require(all.first), b = try #require(all.last { $0.thread.id != a.thread.id })
        let panel = ThreadPanelView(frame: NSRect(x: 0, y: 0, width: 844, height: 780))
        panel.setProjection(a, projectTitle: "demo-repo", workspaceRoot: nil)
        panel.layoutSubtreeIfNeeded()
        panel.timeline.scrollView.contentView.scroll(to: .zero)
        var seen: [(TimelineChange, Int)] = []
        let forward = panel.model.onChange
        panel.model.onChange = { change in seen.append((change, panel.model.items.count)); forward?(change) }
        let rowsOfA = panel.timeline.items.map(\.id)
        panel.beginThreadSwitch(projectTitle: "demo-repo", threadTitle: b.thread.title, keepRows: true)
        panel.layoutSubtreeIfNeeded()
        #expect(panel.timeline.items.map(\.id) == rowsOfA)
        #expect(panel.header.threadTitle == b.thread.title)
        #expect(!panel.composer.isHidden)
        panel.setProjection(b, projectTitle: "demo-repo", workspaceRoot: nil)
        panel.layoutSubtreeIfNeeded()
        #expect(seen.allSatisfy { $0.1 > 0 })
        #expect(seen.first?.0 == .thread)
        #expect(panel.timeline.followsEnd)
        #expect(!panel.switchingThread)
        #expect(panel.timeline.items.map(\.id) != rowsOfA)
    }

    @Test func expandStateLivesInTheModel() throws {
        let projection = try #require(try ThreadPreview.projection(titled: ThreadPreview.commandsThread))
        let panel = ThreadPanelView(frame: NSRect(x: 0, y: 0, width: 844, height: 780))
        panel.setProjection(projection, projectTitle: "demo-repo", workspaceRoot: nil)
        panel.layoutSubtreeIfNeeded()
        let collapsed = panel.model.items.count
        guard case .turnFold(let runId, _, false)? = panel.model.items.first(where: { TimelineView.kind($0.row) == .turnFold })?.row.kind else {
            Issue.record("expected a collapsed fold"); return
        }
        panel.model.toggleRun(runId)
        #expect(panel.model.items.count > collapsed)
        // A new projection of the same thread keeps the fold open.
        panel.setProjection(projection, projectTitle: "demo-repo", workspaceRoot: nil)
        #expect(panel.model.items.count > collapsed)
        // Opening a command row's details lands in the row's UI state, not the view.
        let work = try #require(panel.model.items.first { if case .work = $0.row.kind { true } else { false } })
        guard case .work(let entries, _, _) = work.row.kind else { return }
        panel.model.toggleEntry(entries[0].id)
        #expect(panel.model.items.first { $0.id == work.id }?.ui.expandedEntries == [entries[0].id])
    }
}
