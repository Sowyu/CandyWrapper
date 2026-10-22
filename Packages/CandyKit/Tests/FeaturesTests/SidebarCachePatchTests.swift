import Testing
import DesignSystem
import T3Protocol
import T3Store
@testable import Features

/// The cache's patched and in-place lists equal fresh builds.
@MainActor
struct SidebarCachePatchTests {
    /// A patch under Dither keeps the row in its project section, as a fresh build draws it.
    @Test func ditherPatchKeepsProjectSection() throws {
        var input = ThemeRuntimeInput()
        input.ditherDark = true
        input.ditherLight = true
        ThemeRuntime.apply(input)
        defer { ThemeRuntime.apply(ThemeRuntimeInput()) }
        let projects = [SidebarPreview.project("p0", "project-0")]
        var snap = SidebarPreview.snapshot(projects: projects, threads: [
            SidebarPreview.thread("b1", "with a branch", project: "p0", kind: .read, minutesAgo: 5, extra: ["branch": "fix/x"]),
            SidebarPreview.thread("b2", "no branch", project: "p0", kind: .read, minutesAgo: 9),
        ])
        var state = SidebarListState()
        state.dither = true
        let nowMs = TimestampFormat.nowMs(SidebarPreview.referenceNow)
        let cache = SidebarListCache()
        var items = SidebarListBuilder.items(snapshot: snap, state: state, nowMs: nowMs, cache: cache)
        snap.threads[0].title = "renamed with a branch"
        snap.threads[1].title = "renamed without one"
        let patch = try #require(cache.patch(snapshot: snap, state: state, nowMs: nowMs))
        #expect(patch.count == 2)
        for (at, item) in patch { items[at] = item }
        let fresh = SidebarListBuilder.items(snapshot: snap, state: state, nowMs: nowMs)
        #expect(items == fresh)
        for (_, item) in patch {
            guard case .row(let model) = item else { Issue.record("not a row"); continue }
            #expect(model.inProjectSection)
        }
    }

    /// Every thread changes in place at once: the shelves still equal a fresh build.
    @Test func everyThreadChangedInPlaceMatchesFreshBuild() {
        var state = SidebarListState()
        state.settledExpanded = true
        state.settledVisibleCount = 2_000
        let nowMs = TimestampFormat.nowMs(SidebarPreview.referenceNow)
        let cache = SidebarListCache()
        var snap = SidebarLoadTests.loadSnapshot()
        _ = SidebarListBuilder.items(snapshot: snap, state: state, nowMs: nowMs, cache: cache)
        for i in snap.threads.indices { snap.threads[i].title += " (edited)" }
        let cached = SidebarListBuilder.items(snapshot: snap, state: state, nowMs: nowMs, cache: cache)
        #expect(cached == SidebarListBuilder.items(snapshot: snap, state: state, nowMs: nowMs))
    }
}
