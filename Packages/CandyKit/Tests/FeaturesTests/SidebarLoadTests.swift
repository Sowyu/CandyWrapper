import AppKit
import Testing
import DesignSystem
import T3Protocol
import T3Store
@testable import Features

/// The M10 load sidebar in miniature: 1,580 threads over nine projects, about 1,400 of them settled.
@MainActor
struct SidebarLoadTests {
    static func loadSnapshot() -> ShellSnapshot {
        let projects = (0..<9).map { SidebarPreview.project("p\($0)", "project-\($0)") }
        var threads: [[String: Any]] = []
        for i in 0..<1_580 {
            let p = "p\(i % 9)"
            if i < 1_400 {
                threads.append(SidebarPreview.thread("s\(i)", "update deps romeo \(i)", project: p, kind: .read, minutesAgo: Double(2_000 + i * 7),
                                                     extra: ["settledOverride": "settled", "settledAt": SidebarPreview.iso(Double(1_900 + i * 7))]))
            } else {
                let kinds: [SidebarPreview.Kind] = [.read, .done, .read, .failed, .read]
                threads.append(SidebarPreview.thread("a\(i)", "active thread \(i)", project: p, kind: kinds[i % kinds.count],
                                                     minutesAgo: Double((i - 1_400) * 3 + 1)))
            }
        }
        return SidebarPreview.snapshot(projects: projects, threads: threads)
    }

    /// A change to one thread builds one row model, however many rows the list shows.
    @Test func oneThreadChangeBuildsOneRow() {
        let cache = SidebarListCache()
        var state = SidebarListState()
        state.settledExpanded = true
        state.settledVisibleCount = 2_000
        let nowMs = TimestampFormat.nowMs(SidebarPreview.referenceNow)
        var snap = Self.loadSnapshot()
        let first = SidebarListBuilder.items(snapshot: snap, state: state, nowMs: nowMs, cache: cache)
        #expect(first.count > 1_500)
        let built = cache.rowModelBuilds
        snap.threads[1_500].title = "Renamed"
        snap.threads[3].title = "Renamed settled"
        let items = SidebarListBuilder.items(snapshot: snap, state: state, nowMs: nowMs, cache: cache)
        #expect(cache.rowModelBuilds - built == 2)
        #expect(items == SidebarListBuilder.items(snapshot: snap, state: state, nowMs: nowMs))
        // A clock step a second later changes no label, so nothing rebuilds.
        let again = cache.rowModelBuilds
        _ = SidebarListBuilder.items(snapshot: snap, state: state, nowMs: nowMs + 1_000, cache: cache)
        #expect(cache.rowModelBuilds == again)
    }

    /// The sidebar patches its list: a one-thread change and a clock step touch only their rows, and the
    /// list still equals a fresh build.
    @Test func contentViewPatchesTheList() throws {
        let content = SidebarContentView()
        var now = SidebarPreview.referenceNow
        content.now = { now }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 255, height: 780), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        content.frame = NSRect(x: 0, y: 0, width: 255, height: 780)
        defer { window.contentView = nil }
        let cache = try #require(content.listCache)
        var snap = Self.loadSnapshot()
        content.state.settledExpanded = true
        content.state.settledVisibleCount = 2_000
        content.setSnapshot(snap, animated: false)
        content.layoutSubtreeIfNeeded()
        func fresh() -> [SidebarItem] { SidebarListBuilder.items(snapshot: snap, state: content.state, nowMs: TimestampFormat.nowMs(now)) }
        let generation = cache.generation, built = cache.rowModelBuilds, configured = content.list.configureCount
        snap.threads[1_400].title = "Renamed on screen"
        content.setSnapshot(snap, animated: false, changedThreadIds: [snap.threads[1_400].id])
        #expect(cache.generation == generation) // patched, not rebuilt
        #expect(cache.rowModelBuilds == built + 1)
        #expect(content.list.configureCount <= configured + 1)
        #expect(content.list.items == fresh())
        now = now.addingTimeInterval(3_600)
        content.setSnapshot(snap, animated: false)
        #expect(cache.generation == generation)
        #expect(content.list.items == fresh())
    }

    /// The cache's list equals a fresh build after each kind of change.
    @Test func incrementalBuildsMatchFreshBuilds() {
        let cache = SidebarListCache()
        var state = SidebarListState(activeThreadId: ThreadId("a1500"))
        state.settledExpanded = true
        state.snoozedExpanded = true
        state.settledVisibleCount = 2_000
        var nowMs = TimestampFormat.nowMs(SidebarPreview.referenceNow)
        var snap = Self.loadSnapshot()
        func check(_ what: String) {
            let cached = SidebarListBuilder.items(snapshot: snap, state: state, nowMs: nowMs, cache: cache)
            let fresh = SidebarListBuilder.items(snapshot: snap, state: state, nowMs: nowMs)
            #expect(cached == fresh, "\(what)")
        }
        func iso(_ ms: Int64) -> T3Timestamp { T3Timestamp(epochMs: ms) }
        check("first")
        snap.threads[1_450].settledOverride = .settled
        snap.threads[1_450].settledAt = iso(nowMs - 10_000)
        check("settle")
        snap.threads[5].settledOverride = nil
        snap.threads[5].settledAt = nil
        check("unsettle")
        snap.threads[1_460].snoozedUntil = iso(nowMs + 90_000)
        snap.threads[1_460].snoozedAt = iso(nowMs)
        check("snooze")
        snap.threads[1_470].pinnedAt = iso(nowMs)
        check("pin")
        snap.threads[1_480].activeOrderKey = "a0"
        check("reorder")
        snap.threads.remove(at: 1_490)
        check("delete")
        snap.threads[1_495].title = "Retitled"
        cache.noteChanges([snap.threads[1_495].id]) // as the app's merge hints
        check("hinted rename")
        snap.threads[1_496].title = "Retitled too"
        cache.noteChanges([])
        cache.noteChanges([snap.threads[1_496].id])
        check("two hints add up")
        state.activeThreadId = ThreadId("a1520")
        state.selectedThreadIds = [ThreadId("a1530"), ThreadId("s7")]
        check("select")
        nowMs += 61_000
        check("a minute later")
        nowMs += 60_000
        check("the snooze ends")
        nowMs += 3 * 3_600_000
        check("hours later")
        state.settledExpanded = false
        check("collapse")
        state.projectScopeKey = SidebarModel.buildProjectGroups(snap.projects).first?.key
        check("scope")
    }
}
