import CoreGraphics
import Testing
import T3Protocol
import T3Store
@testable import Features

/// Dither's project sections keep the manual order through new turns, and its drops land where the line shows.
@MainActor
struct SidebarProjectOrderTests {
    let now = Int64(SidebarPreview.referenceNow.timeIntervalSince1970 * 1000)
    let projects = [SidebarPreview.project("p1", "alpha"), SidebarPreview.project("p2", "beta"), SidebarPreview.project("p3", "gamma")]

    /// gamma's thread is the newest, alpha's the oldest.
    func snapshot(newest: String = "c1", extraProjects: [[String: Any]] = [], extraThreads: [[String: Any]] = []) -> ShellSnapshot {
        var threads = [
            SidebarPreview.thread("a1", "Alpha one", project: "p1", kind: .done, minutesAgo: 30),
            SidebarPreview.thread("a2", "Alpha two", project: "p1", kind: .done, minutesAgo: 31),
            SidebarPreview.thread("a3", "Alpha three", project: "p1", kind: .done, minutesAgo: 32),
            SidebarPreview.thread("b1", "Beta one", project: "p2", kind: .done, minutesAgo: 20),
            SidebarPreview.thread("c1", "Gamma one", project: "p3", kind: .done, minutesAgo: 10),
            SidebarPreview.thread("pin", "Pinned alpha", project: "p1", kind: .done, minutesAgo: 40, extra: ["pinnedAt": SidebarPreview.iso(50)]),
        ] + extraThreads
        if let i = threads.firstIndex(where: { $0["id"] as? String == newest }) {
            threads[i] = SidebarPreview.thread(newest, threads[i]["title"] as! String, project: threads[i]["projectId"] as! String,
                                               kind: .done, minutesAgo: 1)
        }
        return SidebarPreview.snapshot(projects: projects + extraProjects, threads: threads)
    }

    func state(_ order: SidebarModel.SortOrder = .manual, _ stored: [String] = []) -> SidebarListState {
        var s = SidebarListState()
        s.dither = true
        s.projectSortOrder = order
        s.projectOrder = stored
        return s
    }

    func sections(_ items: [SidebarItem]) -> [String] {
        items.compactMap { if case .projectHeader(let h) = $0, !h.isPinned { h.label } else { nil } }
    }

    func tops(_ items: [SidebarItem]) -> [CGFloat] {
        var y: CGFloat = 0
        return items.map { item in defer { y += item.height + SidebarListView.gap }; return y }
    }

    func key(_ items: [SidebarItem], _ label: String) -> String {
        items.compactMap { if case .projectHeader(let h) = $0, h.label == label { h.key } else { nil } }[0]
    }

    func index(_ items: [SidebarItem], _ suffix: String) -> Int {
        items.firstIndex { if case .row(let r) = $0 { r.id.rawValue.hasSuffix(suffix) } else { false } }!
    }

    func id(_ items: [SidebarItem], _ suffix: String) -> ThreadId {
        if case .row(let r) = items[index(items, suffix)] { return r.id }
        fatalError()
    }

    @Test func manualSectionsStayPutThroughNewTurnsAndNewProjectsAppend() {
        // Manual with nothing stored: the server's project order, whatever turn is newest.
        let items = SidebarListBuilder.items(snapshot: snapshot(), state: state(), nowMs: now)
        #expect(sections(items) == ["alpha", "beta", "gamma"])
        #expect(sections(SidebarListBuilder.items(snapshot: snapshot(newest: "b1"), state: state(), nowMs: now)) == ["alpha", "beta", "gamma"])
        // Last user message reorders by activity, as T3's setting does.
        #expect(sections(SidebarListBuilder.items(snapshot: snapshot(), state: state(.updatedAt), nowMs: now)) == ["gamma", "beta", "alpha"])

        // gamma dragged above alpha.
        let snap = snapshot()
        let groups = SidebarModel.buildProjectGroups(snap.projects)
        let stored = SidebarModel.movingProjectGroup(key(items, "gamma"), before: key(items, "alpha"), groups: groups, projects: snap.projects, preferred: [])
        #expect(stored == ["/Users/demo/gamma", "/Users/demo/alpha", "/Users/demo/beta"])
        // A new turn in beta, then a new project with a thread: the order holds and delta lands last.
        let later = snapshot(newest: "b1", extraProjects: [SidebarPreview.project("p4", "delta")],
                             extraThreads: [SidebarPreview.thread("d1", "Delta one", project: "p4", kind: .done, minutesAgo: 0.5)])
        #expect(sections(SidebarListBuilder.items(snapshot: later, state: state(.manual, stored), nowMs: now)) == ["gamma", "alpha", "beta", "delta"])
        // To the end, from the stored order.
        let ordered = SidebarModel.orderProjectGroups(SidebarModel.buildProjectGroups(later.projects), projects: later.projects, preferred: stored)
        let moved = SidebarModel.movingProjectGroup(key(items, "gamma"), before: nil, groups: ordered, projects: later.projects, preferred: stored)
        #expect(moved == ["/Users/demo/alpha", "/Users/demo/beta", "/Users/demo/delta", "/Users/demo/gamma"])
    }

    @Test func groupDropLandsBetweenSectionsAndIgnoresItsOwnPlace() {
        let items = SidebarListBuilder.items(snapshot: snapshot(), state: state(), nowMs: now)
        let t = tops(items)
        let alpha = items.firstIndex { if case .projectHeader(let h) = $0 { h.label == "alpha" } else { false } }!
        let gamma = items.firstIndex { if case .projectHeader(let h) = $0 { h.label == "gamma" } else { false } }!
        let gammaKey = key(items, "gamma"), alphaKey = key(items, "alpha")
        // Near alpha's top: before alpha, on alpha's top edge.
        let top = SidebarDitherDropPlanner.groupDrop(items: items, tops: t, dragged: gammaKey, y: t[alpha] + 3)
        #expect(top == SidebarDitherDrop(lineY: t[alpha], action: .group(before: alphaKey)))
        // Over its own header or just below its section: nothing moves, no line.
        #expect(SidebarDitherDropPlanner.groupDrop(items: items, tops: t, dragged: gammaKey, y: t[gamma] + 2) == nil)
        #expect(SidebarDitherDropPlanner.groupDrop(items: items, tops: t, dragged: gammaKey, y: t[gamma] + 70) == nil)
        // alpha to below gamma: the end.
        let end = SidebarDitherDropPlanner.groupDrop(items: items, tops: t, dragged: alphaKey, y: t[gamma] + 70)
        #expect(end?.action == .group(before: nil))
        // The section drag dims the header and every row in it.
        #expect(SidebarDitherDropPlanner.groupKeys(items, alphaKey).count == 4)
    }

    @Test func threadDropReordersInsideItsProjectAndPinsOrUnpins() throws {
        let items = SidebarListBuilder.items(snapshot: snapshot(), state: state(), nowMs: now)
        let t = tops(items)
        let alphaKey = key(items, "alpha")
        let a1 = id(items, "a1"), a2 = id(items, "a2"), a3 = id(items, "a3"), pin = id(items, "pin")
        let active = SidebarDitherDropPlanner.shown(items, .active)
        // a3 dragged to the line above a1.
        let up = try #require(SidebarDitherDropPlanner.threadDrop(items: items, tops: t, dragged: a3, ownSection: alphaKey, y: t[index(items, "a1")] + 4))
        #expect(up.lineY == t[index(items, "a1")] - SidebarListView.gap / 2)
        guard case .thread(let target) = up.action else { Issue.record("not a thread drop"); return }
        #expect(target.section == .active)
        #expect(Array(target.activeOrder.prefix(3)) == [a3, a1, a2])
        #expect(Set(target.activeOrder) == Set(active))
        // Dropped where it already is: nothing.
        #expect(SidebarDitherDropPlanner.threadDrop(items: items, tops: t, dragged: a3, ownSection: alphaKey, y: t[index(items, "a3")] + 40) == nil)
        // Another project's section takes no thread.
        #expect(SidebarDitherDropPlanner.threadDrop(items: items, tops: t, dragged: a3, ownSection: alphaKey, y: t[index(items, "b1")] + 20) == nil)
        // Into Pinned: pinned first-to-last with a2 after the pinned thread.
        let pinDrop = try #require(SidebarDitherDropPlanner.threadDrop(items: items, tops: t, dragged: a2, ownSection: alphaKey, y: t[index(items, "pin")] + 40))
        #expect(pinDrop.action == .thread(SidebarDropTarget(section: .pinned, pinnedOrder: [pin, a2], activeOrder: active.filter { $0 != a2 })))
        // The pinned thread dropped into its project's section unpins there.
        let unpin = try #require(SidebarDitherDropPlanner.threadDrop(items: items, tops: t, dragged: pin, ownSection: alphaKey, y: t[index(items, "a2")] + 4))
        guard case .thread(let u) = unpin.action else { Issue.record("not a thread drop"); return }
        #expect(u.section == .active && u.pinnedOrder.isEmpty && Array(u.activeOrder.prefix(3)) == [a1, pin, a2])
        // The Settled header settles.
        let settled = items.firstIndex { if case .shelfHeader(.settled, _, _) = $0 { true } else { false } }!
        let settle = SidebarDitherDropPlanner.threadDrop(items: items, tops: t, dragged: a1, ownSection: alphaKey, y: t[settled] + 4)
        #expect(settle?.lineY == nil)
        if case .thread(let s)? = settle?.action { #expect(s.section == .settled) } else { Issue.record("no settle") }
    }
}
