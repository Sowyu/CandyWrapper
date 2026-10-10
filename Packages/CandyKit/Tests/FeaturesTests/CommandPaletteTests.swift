import AppKit
import Testing
@testable import Features
import DesignSystem

/// Ported from apps/web/src/components/CommandPalette.logic.test.ts, plus the palette's key routing.
@MainActor
@Suite struct CommandPaletteTests {
    func thread(_ id: String, _ title: String, recency: Int64, extra: [String] = []) -> PaletteEntry {
        PaletteEntry(value: "thread:\(id)", searchTerms: [title, "Project"] + extra + [id], title: title,
                     searchRecency: recency, icon: .messageSquare, action: .run({}, keepOpen: false))
    }

    func action(_ value: String, _ terms: [String], ran: (() -> Void)? = nil) -> PaletteEntry {
        PaletteEntry(value: value, searchTerms: terms, title: terms[0], icon: .squarePen, action: .run({ ran?() }, keepOpen: false))
    }

    func values(_ groups: [PaletteGroup]) -> [String] { groups.flatMap { $0.items.map(\.value) } }

    @Test func titleMatchesOutrankProjectMatches() {
        let items = [thread("context", "Fix navbar spacing", recency: 20), thread("title", "Project kickoff notes", recency: 19)]
        let groups = PaletteSearch.filter([], query: "project", isInSubmenu: false, projectItems: [], threadItems: items)
        #expect(groups.map(\.value) == ["threads-search"])
        #expect(values(groups) == ["thread:title", "thread:context"])
    }

    @Test func titleMatchesShareATierBrokenByRecency() {
        let items = [
            thread("old-prefix", "Convex InvalidCursor in Convex threads query", recency: 2),
            thread("recent-title", "Disable Convex schema validation", recency: 24),
            thread("recent-content", "Fix schema validation", recency: 25, extra: ["Please check Convex"]),
        ]
        let groups = PaletteSearch.filter([], query: "convex", isInSubmenu: false, projectItems: [], threadItems: items)
        #expect(values(groups) == ["thread:recent-title", "thread:old-prefix", "thread:recent-content"])
    }

    @Test func idMatchesNeverOutrankTitles() {
        let items = [thread("thread-alpha-1234", "Unrelated work", recency: 5), thread("thread-other-9999", "Fix thread-alpha-1234 flakes", recency: 4)]
        let groups = PaletteSearch.filter([], query: "  THREAD-ALPHA-1234  ", isInSubmenu: false, projectItems: [], threadItems: items)
        #expect(values(groups) == ["thread:thread-other-9999", "thread:thread-alpha-1234"])
    }

    @Test func normalizesAccentsAndCase() {
        #expect(PaletteSearch.normalize("  Café   GIT ") == "cafe git")
        let groups = PaletteSearch.filter([PaletteGroup(value: "actions", label: "Actions", items: [action("a", ["Résumé builder"])])],
                                          query: "RESUME", isInSubmenu: false, projectItems: [], threadItems: [])
        #expect(values(groups) == ["a"])
    }

    @Test func actionsFilterAndRecentThreads() {
        let root = [
            PaletteGroup(value: "actions", label: "Actions", items: [action("new", ["new thread"]), action("usage", ["usage"])]),
            PaletteGroup(value: "recent-threads", label: "Recent Threads", items: [thread("t", "new thread ideas", recency: 1)]),
        ]
        let projects = [action("project:x", ["new project x"])]
        // Empty query: the root as is.
        #expect(PaletteSearch.filter(root, query: "", isInSubmenu: false, projectItems: projects, threadItems: []).map(\.value) == ["actions", "recent-threads"])
        // `>` keeps the actions group only.
        #expect(PaletteSearch.filter(root, query: ">", isInSubmenu: false, projectItems: projects, threadItems: []).map(\.value) == ["actions"])
        #expect(values(PaletteSearch.filter(root, query: ">new", isInSubmenu: false, projectItems: projects, threadItems: [])) == ["new"])
        // A query hides Recent Threads and adds the search groups.
        let searched = PaletteSearch.filter(root, query: "new", isInSubmenu: false, projectItems: projects, threadItems: [thread("t", "new thread ideas", recency: 1)])
        #expect(searched.map(\.value) == ["actions", "projects-search", "threads-search"])
    }

    @Test func enumeratesJumpShortcuts() {
        let items = PaletteSearch.enumerate((0..<11).map { action("p\($0)", ["p\($0)"]) })
        #expect(items[0].shortcutCommand == "thread.jump.1")
        #expect(items[8].shortcutCommand == "thread.jump.9")
        #expect(items[9].shortcutCommand == nil)
    }

    @Test func keyboardRouting() {
        var ran: [String] = []
        var closed = 0
        let sub = PalettePage(addonIcon: .monitor, groups: [PaletteGroup(value: "appearance", label: "Change appearance", items: [
            action("light", ["Light"]) { ran.append("light") }, action("dark", ["Dark"]) { ran.append("dark") },
        ])])
        let root = [PaletteGroup(value: "actions", label: "Actions", items: [
            action("first", ["First"]) { ran.append("first") },
            PaletteEntry(value: "appearance", searchTerms: ["Change appearance"], title: "Change appearance", icon: .monitor, action: .submenu(sub)),
            action("last", ["Last"]) { ran.append("last") },
        ])]
        let palette = CommandPaletteController(source: .init(rootGroups: { root }))
        palette.onClose = { closed += 1 }
        // Opens with the first row highlighted.
        #expect(palette.view.highlightedIndex == 0)
        _ = palette.handleCommand(#selector(NSResponder.moveDown(_:)))
        _ = palette.handleCommand(#selector(NSResponder.insertNewline(_:)))
        // A submenu: back arrow, hidden highlight, Enter runs its first row.
        #expect(palette.isInSubmenu)
        #expect(palette.view.highlightedIndex == nil)
        #expect(palette.view.showsBackButton)
        _ = palette.handleCommand(#selector(NSResponder.insertNewline(_:)))
        #expect(ran == ["light"])
        #expect(closed == 1)
        // Backspace on an empty query leaves the submenu.
        #expect(palette.handleCommand(#selector(NSResponder.deleteBackward(_:))))
        #expect(!palette.isInSubmenu)
        // ArrowDown after the highlight was cleared lands on the first row.
        _ = palette.handleCommand(#selector(NSResponder.moveDown(_:)))
        #expect(palette.view.highlightedIndex == 0)
        _ = palette.handleCommand(#selector(NSResponder.moveUp(_:)))
        #expect(palette.view.highlightedIndex == 2)
        // Escape asks to close; Backspace in the root is plain editing.
        #expect(!palette.handleCommand(#selector(NSResponder.deleteBackward(_:))))
        _ = palette.handleCommand(#selector(NSResponder.cancelOperation(_:)))
        #expect(closed == 2)
    }

    @Test func jumpRunsTheItemShowingThatShortcut() {
        var ran: [String] = []
        let items = PaletteSearch.enumerate([action("a", ["A"]) { ran.append("a") }, action("b", ["B"]) { ran.append("b") }])
        let palette = CommandPaletteController(source: .init(rootGroups: { [PaletteGroup(value: "projects", label: "Projects", items: items)] }))
        #expect(palette.handleJump("thread.jump.2"))
        #expect(ran == ["b"])
        #expect(!palette.handleJump("chat.new"))
    }
}
