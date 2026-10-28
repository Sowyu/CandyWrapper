import Testing
import T3Protocol
import T3Store
@testable import Features

@MainActor
struct LazyShellSidebarTests {
    @Test func countsIncludeOmittedRowsWithoutCountingRetainedExceptionsTwice() {
        var snapshot = SidebarPreview.snapshot(projects: [SidebarPreview.project("p", "Sandbox")], threads: [
            SidebarPreview.thread("recent", "Recent", project: "p", kind: .read, minutesAgo: 0, extra: [
                "settledOverride": "settled", "settledAt": "2026-10-22T00:00:00.000Z"]),
            SidebarPreview.thread("loaded", "Loaded page", project: "p", kind: .read, minutesAgo: 0, extra: [
                "settledOverride": "settled", "settledAt": "2026-10-19T00:00:00.000Z"]),
            SidebarPreview.thread("snoozed", "Snoozed exception", project: "p", kind: .read, minutesAgo: 0, extra: [
                "settledOverride": "settled", "settledAt": "2026-10-18T00:00:00.000Z", "snoozedUntil": "2030-01-01T00:00:00.000Z"])
        ])
        snapshot.olderSettled = .init(before: "2026-10-20T00:00:00.000Z", asOfSequence: 10,
                                     counts: [.init(projectId: "p", count: 100)])
        let context = SidebarListBuilder.Context(snapshot: snapshot, state: SidebarListState(), nowMs: 1_800_000_000_000)
        #expect(context.shelves.settled.count == 2)
        #expect(context.hiddenSettledCount == 98)
        let items = SidebarListBuilder.items(snapshot: snapshot, state: SidebarListState(), nowMs: 1_800_000_000_000)
        #expect(items.contains { if case .shelfHeader(.settled, let label, _, _) = $0 { label == "Settled (100)" } else { false } })
    }

    @Test func omittedOnlyShelfHasPagingAndCountOnlyUpdatesInvalidateCache() {
        var snapshot = SidebarPreview.snapshot(projects: [SidebarPreview.project("p", "Sandbox")], threads: [])
        snapshot.olderSettled = .init(before: "2026-10-20T00:00:00.000Z", asOfSequence: 10,
                                     counts: [.init(projectId: "p", count: 100)])
        let cache = SidebarListCache()
        let state = SidebarListState()
        let first = SidebarListBuilder.items(snapshot: snapshot, state: state, nowMs: 1_800_000_000_000, cache: cache)
        #expect(first.contains { if case .shelfHeader(.settled, let label, _, _) = $0 { label == "Settled (100)" } else { false } })
        snapshot.olderSettled?.counts[0].count = 99
        let changed = SidebarListBuilder.items(snapshot: snapshot, state: state, nowMs: 1_800_000_000_000, cache: cache)
        #expect(changed.contains { if case .shelfHeader(.settled, let label, _, _) = $0 { label == "Settled (99)" } else { false } })
        var expanded = state
        expanded.settledExpanded = true
        let paged = SidebarListBuilder.items(snapshot: snapshot, state: expanded, nowMs: 1_800_000_000_000, cache: cache)
        #expect(paged.contains { if case .showMore(let count) = $0 { count == 25 } else { false } })
    }
}
