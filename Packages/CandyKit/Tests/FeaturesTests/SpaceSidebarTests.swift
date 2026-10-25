import AppKit
import DesignSystem
import SpaceModel
import Testing
@testable import Features

/// Space's page tree and the sidebar's Space mode (docs/space.md "Space mode").
@MainActor
struct SpaceSidebarTests {
    /// Uni { COMP2310, MATH2221 }, Board (a board view) { Card }, Journal.
    func fixture() -> (InMemorySpacePageStore, [String: PageID]) {
        let store = InMemorySpacePageStore()
        var ids: [String: PageID] = [:]
        ids["uni"] = store.createPage(title: "Uni", now: 1)
        ids["comp"] = store.createPage(in: ids["uni"], title: "COMP2310 notes", now: 2)
        ids["math"] = store.createPage(in: ids["uni"], title: "MATH2221 notes", now: 3)
        ids["board"] = store.createPage(title: "Reading list", now: 4)
        ids["card"] = store.createPage(in: ids["board"], title: "Card", now: 5)
        var board = store.pages[ids["board"]!]!
        board.view = .board
        store.put([ids["board"]!: board])
        ids["journal"] = store.createPage(title: "Journal", now: 6)
        return (store, ids)
    }

    func titles(_ store: SpacePageStore, expanded: Set<PageID> = [], query: String = "") -> [String] {
        SpaceTree.rows(store.pages, expanded: expanded, query: query).map { String(repeating: "  ", count: $0.depth) + $0.title }
    }

    @Test func treeShowsPagesInOrderAndHidesBoardItems() {
        let (store, ids) = fixture()
        #expect(titles(store) == ["Uni", "Reading list", "Journal"])
        #expect(titles(store, expanded: [ids["uni"]!, ids["board"]!]) == ["Uni", "  COMP2310 notes", "  MATH2221 notes", "Reading list", "Journal"])
        let rows = SpaceTree.rows(store.pages, expanded: [])
        #expect(rows[0].hasChildren && !rows[0].expanded)
        #expect(!rows[1].hasChildren, "a board's cards don't count as tree children")
    }

    @Test func moveReordersNestsAndRefusesCycles() {
        let (store, ids) = fixture()
        let open: Set<PageID> = [ids["uni"]!]
        #expect(store.move(ids["journal"]!, to: nil, before: ids["uni"]))
        #expect(titles(store) == ["Journal", "Uni", "Reading list"])
        #expect(store.move(ids["journal"]!, to: ids["uni"], before: ids["math"]))
        #expect(titles(store, expanded: open) == ["Uni", "  COMP2310 notes", "  Journal", "  MATH2221 notes", "Reading list"])
        #expect(!store.move(ids["uni"]!, to: ids["journal"], before: nil), "a page can't go inside its own child")
        #expect(!store.move(ids["uni"]!, to: ids["uni"], before: nil))
        #expect(!store.move(ids["journal"]!, to: ids["board"], before: nil), "the tree hides a board's items")
        #expect(store.move(ids["comp"]!, to: nil, before: nil))
        #expect(titles(store, expanded: open) == ["Uni", "  Journal", "  MATH2221 notes", "Reading list", "COMP2310 notes"])
        // Repeated moves between the same two neighbours keep finding keys.
        for _ in 0..<50 { #expect(store.move(ids["comp"]!, to: ids["uni"], before: ids["math"])); #expect(store.move(ids["journal"]!, to: ids["uni"], before: ids["comp"])) }
        #expect(titles(store, expanded: open) == ["Uni", "  Journal", "  COMP2310 notes", "  MATH2221 notes", "Reading list"])
    }

    @Test func dropPlanMapsThePointerToAMove() {
        let (store, ids) = fixture()
        let rows = SpaceTree.rows(store.pages, expanded: [ids["uni"]!])
        let pitch: CGFloat = 30
        // Rows: Uni, COMP, MATH, Reading list (board), Journal.
        let journal = ids["journal"]!
        #expect(SpaceDrop.plan(y: 2, rows: rows, pitch: pitch, dragged: journal, pages: store.pages) == .before(ids["uni"]!))
        #expect(SpaceDrop.plan(y: 15, rows: rows, pitch: pitch, dragged: journal, pages: store.pages) == .into(ids["uni"]!))
        #expect(SpaceDrop.plan(y: 28, rows: rows, pitch: pitch, dragged: journal, pages: store.pages) == .after(ids["uni"]!))
        #expect(SpaceDrop.plan(y: 95, rows: rows, pitch: pitch, dragged: journal, pages: store.pages) == .before(ids["board"]!), "no nesting into a board")
        #expect(SpaceDrop.plan(y: 400, rows: rows, pitch: pitch, dragged: journal, pages: store.pages) == .end)
        #expect(SpaceDrop.plan(y: 45, rows: rows, pitch: pitch, dragged: ids["uni"]!, pages: store.pages) == nil, "not onto its own child")
        // After an open parent: its first child.
        let after = SpaceDrop.after(ids["uni"]!).target(rows: rows, dragged: journal, pages: store.pages)
        #expect(after.parent == ids["uni"] && after.before == ids["comp"])
        let afterMath = SpaceDrop.after(ids["math"]!).target(rows: rows, dragged: journal, pages: store.pages)
        #expect(afterMath.parent == ids["uni"] && afterMath.before == nil)
        let afterBoard = SpaceDrop.after(ids["board"]!).target(rows: rows, dragged: ids["uni"]!, pages: store.pages)
        #expect(afterBoard.parent == nil && afterBoard.before == journal)
    }

    @Test func searchFiltersToMatchesAndTheirAncestors() {
        let (store, _) = fixture()
        #expect(titles(store, query: "math") == ["Uni", "  MATH2221 notes"])
        #expect(titles(store, query: "NOTES") == ["Uni", "  COMP2310 notes", "  MATH2221 notes"])
        #expect(titles(store, query: "uni notes").isEmpty, "every word must match one title")
        #expect(titles(store, query: "otes").isEmpty, "word prefixes only")
        #expect(titles(store, query: "card").isEmpty, "a board's items stay out")
        let rows = SpaceTree.rows(store.pages, expanded: [], query: "math")
        #expect(!rows[0].matches && rows[1].matches)
        store.rename(store.createPage(title: "Café plans"), "Café plans")
        #expect(titles(store, query: "cafe") == ["Café plans"])
    }

    @Test func trashRestoreDuplicateAndDelete() {
        let (store, ids) = fixture()
        store.trash(ids["uni"]!, now: 10)
        store.trash(ids["journal"]!, now: 20)
        #expect(titles(store) == ["Reading list"])
        #expect(store.trashed == [ids["journal"]!, ids["uni"]!], "newest first")
        #expect(!store.isLive(ids["comp"]!), "children go with their parent")
        store.restore(ids["uni"]!)
        #expect(store.isLive(ids["comp"]!))
        // A child restored after its parent went to Trash lands at the top.
        store.trash(ids["math"]!)
        store.trash(ids["uni"]!)
        store.restore(ids["math"]!)
        #expect(store.pages[ids["math"]!]!.parent == nil)
        store.restore(ids["uni"]!)
        let copy = store.duplicate(ids["uni"]!, now: 30)!
        #expect(titles(store, expanded: [copy]) == ["Uni", "Uni copy", "  COMP2310 notes", "Reading list", "MATH2221 notes"])
        store.remove(ids["journal"]!)
        #expect(store.pages[ids["journal"]!] == nil && store.trashed.isEmpty)
    }

    @Test func spaceIsMadeOnlyOnceItTurnsOn() throws {
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous) }
        var dither = previous
        dither.ditherLight = true; dither.ditherDark = true
        ThemeRuntime.apply(dither)
        let defaults = try #require(UserDefaults(suiteName: "SpaceSidebarTests.\(UUID().uuidString)"))
        let settings = SpaceSettings(defaults: defaults)
        var made = 0
        settings.whenFirstActive { made += 1 }
        #expect(made == 0, "an off launch makes nothing")
        settings.enabled = true
        #expect(made == 1)
        settings.enabled = false
        settings.enabled = true
        #expect(made == 1, "made once, then kept across off and on")
        let on = SpaceSettings(defaults: defaults)
        on.whenFirstActive { made += 1 }
        #expect(made == 2, "an on launch makes it at once")
    }

    @Test func spaceModeShowsOnlyWithItsViewUnderRedesign() throws {
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous) }
        var dither = previous
        dither.ditherLight = true; dither.ditherDark = true
        ThemeRuntime.apply(dither)
        let defaults = try #require(UserDefaults(suiteName: "SpaceSidebarTests.\(UUID().uuidString)"))
        let content = SidebarContentView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 255, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        content.frame = NSRect(x: 0, y: 0, width: 255, height: 800)
        content.layoutSubtreeIfNeeded()
        // Switch off: no Space row.
        #expect(content.spaceRow.isHidden)
        #expect(!content.subviews.contains { $0 is SpaceSidebarView })

        let (store, _) = fixture()
        let space = SpaceSidebarView(store: store, settings: SpaceSettings(defaults: defaults))
        content.space = space
        content.layoutSubtreeIfNeeded()
        #expect(!content.spaceRow.isHidden && space.isHidden)
        let automations = content.navRows[2].frame, settings = content.navRows[3].frame
        #expect(content.spaceRow.frame.minY > automations.minY && content.spaceRow.frame.minY < settings.minY, "Space sits between Automations and Settings")
        var opened = false
        content.actions.openSpace = { opened = true }
        content.spaceRow.performAction()
        #expect(opened)

        content.spaceMode = true
        content.layoutSubtreeIfNeeded()
        #expect(!space.isHidden)
        #expect(content.scrollArea.isHidden && content.search.isHidden && content.spaceRow.isHidden && content.navSection.isHidden)
        #expect(content.navRows.allSatisfy { $0.isHidden })
        #expect(!content.accountRow.isHidden, "the account footer stays")
        #expect(space.tree.rows.map(\.title) == ["Uni", "Reading list", "Journal"])
        #expect(space.newPageRow.frame.maxY <= content.accountRow.frame.minY)

        content.spaceMode = false
        content.layoutSubtreeIfNeeded()
        #expect(space.isHidden && !content.scrollArea.isHidden && !content.search.isHidden && !content.spaceRow.isHidden)

        // The switch going off removes Space's view and leaves Space mode.
        content.spaceMode = true
        content.space = nil
        content.layoutSubtreeIfNeeded()
        #expect(!content.spaceMode && content.spaceRow.isHidden && !content.scrollArea.isHidden)
        window.contentView = nil
    }

    @Test func newPageOpensAndSearchNarrowsTheTree() throws {
        let defaults = try #require(UserDefaults(suiteName: "SpaceSidebarTests.\(UUID().uuidString)"))
        let (store, ids) = fixture()
        let space = SpaceSidebarView(store: store, settings: SpaceSettings(defaults: defaults))
        var opened: [PageID] = []
        space.actions.openPage = { opened.append($0) }
        let child = space.newPage(in: ids["uni"])
        #expect(opened == [child])
        #expect(store.pages[child]?.parent == ids["uni"])
        #expect(space.tree.rows.map(\.title) == ["Uni", "COMP2310 notes", "MATH2221 notes", "", "Reading list", "Journal"], "the parent opens to show it")
        space.tree.query = "jour"
        #expect(space.tree.rows.map(\.title) == ["Journal"])
    }
}
