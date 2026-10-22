import Testing
import T3Protocol
@testable import Features

/// Dither's tab strip state: open, replace, switch, close (the selected one too), reorder and prune.
@MainActor
struct DitherTabListTests {
    private func thread(_ s: String) -> RouteHistory.Route { .thread(ThreadId(s)) }
    private func keys(_ l: DitherTabList) -> [String] { l.tabs.map(DitherTabList.key) }

    @Test func navigatingReplacesNewTabInsertsOpenRouteSwitches() {
        var l = DitherTabList()
        l.shown(thread("a"), newTab: false)
        l.shown(thread("b"), newTab: false)
        #expect(keys(l) == ["thread:b"])
        l.shown(thread("c"), newTab: true)
        l.shown(.settings(.general), newTab: true)
        #expect(keys(l) == ["thread:b", "thread:c", "settings"] && l.selected == 2)
        l.shown(thread("b"), newTab: true)
        #expect(keys(l) == ["thread:b", "thread:c", "settings"] && l.selectedKey == "thread:b")
        l.shown(thread("d"), newTab: true)
        #expect(keys(l) == ["thread:b", "thread:d", "thread:c", "settings"] && l.selected == 1)
    }

    @Test func closingTheSelectedTabSelectsItsNeighbor() {
        var l = DitherTabList()
        for s in ["a", "b", "c"] { l.shown(thread(s), newTab: true) }
        _ = l.select("thread:b")
        var c = l.close("thread:b"); #expect(c)
        #expect(l.selectedKey == "thread:c")
        c = l.close("thread:c"); #expect(c)
        #expect(l.selectedKey == "thread:a")
        l.shown(thread("x"), newTab: true)
        c = l.close("thread:a"); #expect(!c)
        #expect(l.selectedKey == "thread:x" && l.selected == 0)
        c = l.close("thread:x"); #expect(c)
        #expect(l.tabs.isEmpty && l.selectedRoute == nil)
        let reselected = l.select("thread:a"); #expect(reselected == nil)
    }

    @Test func reorderKeepsTheSelectionAndPruneKeepsTheSelectedTab() {
        var l = DitherTabList()
        for s in ["a", "b", "c", "d"] { l.shown(thread(s), newTab: true) }
        _ = l.select("thread:b")
        l.move("thread:b", to: 3)
        #expect(keys(l) == ["thread:a", "thread:c", "thread:d", "thread:b"] && l.selected == 3)
        l.move("thread:d", to: 0)
        #expect(keys(l) == ["thread:d", "thread:a", "thread:c", "thread:b"] && l.selectedKey == "thread:b")
        l.prune { $0 == thread("c") }
        #expect(keys(l) == ["thread:c", "thread:b"] && l.selectedKey == "thread:b")
    }

    @Test func theOldestUnselectedTabDropsPastTheLimit() {
        var l = DitherTabList()
        for i in 0...DitherTabList.limit { l.shown(thread("\(i)"), newTab: true) }
        #expect(l.tabs.count == DitherTabList.limit && l.selectedKey == "thread:\(DitherTabList.limit)")
        #expect(!keys(l).contains("thread:0"))
    }
}
