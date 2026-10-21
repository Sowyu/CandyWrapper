import AppKit
import Testing
@testable import Features
import DesignSystem
import T3Protocol

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

    /// The ASCII fast path gives what the Unicode path gives.
    @Test func asciiNormalizeMatchesUnicodePath() {
        func slow(_ s: String) -> String {
            String(String.UnicodeScalarView(s.decomposedStringWithCompatibilityMapping.unicodeScalars
                .filter { !CharacterSet.nonBaseCharacters.contains($0) })).lowercased()
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        for s in ["", "   ", "Update Deps ROMEO 200", "\tA\n\r b\u{0B}\u{0C}c  ", "~!@#$%^&*()_+{}|:\"<>?`-=[]\\;',./ Z", "x"] {
            #expect(PaletteSearch.normalizeASCII(s) == slow(s))
        }
        #expect(PaletteSearch.normalizeASCII("Café") == nil)
        #expect(PaletteSearch.normalizeASCII("a\u{1F}b") == nil)
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

    /// Go to file opens with its first file highlighted, before anything is typed (`autoHighlight="always"`,
    /// CommandPalette.tsx:2995-2996, 3471).
    @Test func modeHighlightsItsFirstRowOnOpen() {
        let palette = CommandPaletteController(source: .init(rootGroups: { [] }))
        let files = [PaletteGroup(value: "files", label: "demo-repo", items: [action("a.py", ["a.py"]) {}, action("b.md", ["b.md"]) {}])]
        palette.setMode(.init(name: "files", placeholder: "Search files\u{2026}", footerActionLabel: "Open file") { _ in (files, "") })
        #expect(palette.view.highlightedIndex == 0)
    }

    /// A key's search waits for the glyph to commit, but Enter right after it runs the row that search finds.
    @Test func enterAfterTypingRunsTheFilteredRow() {
        var ran: [String] = []
        let root = [PaletteGroup(value: "actions", label: "Actions", items: [action("alpha", ["Alpha"]) { ran.append("alpha") },
                                                                             action("beta", ["Beta"]) { ran.append("beta") }])]
        let palette = CommandPaletteController(source: .init(rootGroups: { root }))
        palette.view.input.onChange?("bet")
        _ = palette.handleCommand(#selector(NSResponder.insertNewline(_:)))
        #expect(ran == ["beta"])
    }

    @Test func jumpRunsTheItemShowingThatShortcut() {
        var ran: [String] = []
        let items = PaletteSearch.enumerate([action("a", ["A"]) { ran.append("a") }, action("b", ["B"]) { ran.append("b") }])
        let palette = CommandPaletteController(source: .init(rootGroups: { [PaletteGroup(value: "projects", label: "Projects", items: items)] }))
        #expect(palette.handleJump("thread.jump.2"))
        #expect(ran == ["b"])
        #expect(!palette.handleJump("chat.new"))
        #expect(!palette.handleJump("terminal.toggle"))
    }

    /// New-thread shortcuts run the row showing them while the palette is open (#19055, CommandPalette.tsx:2318-2333).
    @Test func newThreadShortcutRunsItsRow() {
        var ran: [String] = []
        var row = action("new", ["New thread"]) { ran.append("new") }
        row.shortcutCommand = "chat.new"
        let palette = CommandPaletteController(source: .init(rootGroups: { [PaletteGroup(value: "actions", label: "Actions", items: [row])] }))
        #expect(palette.handleJump("chat.new"))
        #expect(ran == ["new"])
        #expect(!palette.handleJump("chat.newLocal"))
    }

    /// Escape out of Go to file opened from the palette gives back the query that led there (#15940,
    /// CommandPalette.logic.ts:114-124); a shortcut-opened mode returns to an empty query.
    @Test func leavingAChildModeRestoresTheQuery() {
        var palette: CommandPaletteController!
        let files = PaletteEntry(value: "files", searchTerms: ["Go to file"], title: "Go to file", icon: .search,
                                 action: .run({ palette.setMode(.init(name: "files", placeholder: "", footerActionLabel: "") { _ in ([], "") }) }, keepOpen: true))
        palette = CommandPaletteController(source: .init(rootGroups: { [PaletteGroup(value: "actions", label: "Actions", items: [files])] }))
        palette.view.input.onChange?("go to")
        _ = palette.handleCommand(#selector(NSResponder.insertNewline(_:)))
        #expect(palette.mode?.name == "files" && palette.query.isEmpty)
        palette.setMode(nil)
        #expect(palette.query == "go to")
        palette.setMode(.init(name: "files", placeholder: "", footerActionLabel: "") { _ in ([], "") })
        palette.setMode(nil)
        #expect(palette.query.isEmpty)
    }

    /// `ThreadSearchPullRequestNumber`: the badge shows only when the query names the pull request.
    @Test func threadSearchPullRequestBadge() {
        let thread = ComposerFeedbackTests.shell(#""status":"idle","linkedPullRequest":{"projectId":"p","repository":"o/r","number":123,"url":"https://github.com/o/r/pull/123"}"#)
        #expect(ThreadPullRequests.searchTerms(thread) == ["#123", "o/r#123", "https://github.com/o/r/pull/123"])
        #expect(SidebarPullRequestBadge.search(thread, query: "#123")?.text == "123")
        #expect(SidebarPullRequestBadge.search(thread, query: "o/r 123")?.text == "123")
        #expect(SidebarPullRequestBadge.search(thread, query: "#124") == nil)
        #expect(SidebarPullRequestBadge.search(thread, query: " ") == nil)
    }
}
