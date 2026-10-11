import AppKit
import CoreGraphics
import Testing
import T3Protocol
import T3Store
@testable import Features

/// The drag planner against Sidebar.logic.test.ts's shapes: the empty pinned target, the move order and
/// the preview's room for labels.
struct SidebarSortPlannerTests {
    let a1 = ThreadId("env:a1"), a2 = ThreadId("env:a2"), s1 = ThreadId("env:s1")

    var items: [SidebarSortItem] {
        [.marker(.pinnedHeader), .marker(.pinnedDivider), .marker(.activePlaceholder),
         .thread(a1, .active), .thread(a2, .active), .marker(.settledHeader), .marker(.settledPlaceholder), .thread(s1, .settled)]
    }

    @Test func emptyPinnedBlockTakesADropAtTheTop() throws {
        let pin = try #require(SidebarSortPlanner.target(items, active: 4, over: 0))
        #expect(pin.section == .pinned)
        #expect(pin.pinnedOrder == [a2])
        #expect(pin.activeOrder == [a1])
        let first = try #require(SidebarSortPlanner.target(items, active: 4, over: 2))
        #expect(first.section == .active)
        #expect(first.activeOrder == [a2, a1])
        let settle = try #require(SidebarSortPlanner.target(items, active: 4, over: 7))
        #expect(settle.section == .settled)
    }

    @Test func previewOpensLabelRoomAndTheGap() throws {
        // Rest: markers zero high at the slot they open in; a1 at 0, a2 at 83, the settled header at 166.
        let tops: [CGFloat] = [0, 0, 0, 0, 83, 166, 199, 199]
        let heights: [CGFloat] = [0, 0, 0, 82, 82, 32, 0, 36]
        let target = try #require(SidebarSortPlanner.target(items, active: 4, over: 0))
        let y = SidebarSortPlanner.project(items, tops: tops, heights: heights, active: 4, target: target,
                                           context: .init(settledExpanded: true))
        // Pinned label (24), the lifted card's slot (82), the Active label (24), then a1.
        #expect(y[0] == 0)
        #expect(y[1] == 108) // 24 + 1 + 82 + 1
        #expect(y[3] == 133) // then 24 + 1
        // The active placeholder stays hidden while active has a row; the lifted row keeps its own place.
        #expect(y[2] == nil)
        #expect(y[4] == 83)
    }

    @Test func dropVerbFollowsTheDestination() {
        #expect(SidebarDropVerb.resolve(from: .active, to: .pinned) == .pin)
        #expect(SidebarDropVerb.resolve(from: .pinned, to: .active) == .unpin)
        #expect(SidebarDropVerb.resolve(from: .snoozed, to: .active) == .wake)
        #expect(SidebarDropVerb.resolve(from: .active, to: .snoozed) == nil)
        #expect(SidebarDropVerb.resolve(from: .settled, to: .settled) == nil)
    }
}

@MainActor
struct SidebarShelfRestoreTests {
    @Test func shelvesComeBackExpanded() throws {
        let suite = "dev.candywrapper.tests.shelves"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: SidebarContentView.settledExpandedKey)
        defaults.set(true, forKey: SidebarContentView.snoozedExpandedKey)
        let content = SidebarContentView()
        content.shelfDefaults = defaults
        #expect(content.state.settledExpanded)
        #expect(content.state.snoozedExpanded)
        #expect(!content.state.workingExpanded)
    }
}
