import AppKit
import Testing
@testable import Features
import DesignSystem
import T3Protocol

/// Ported from apps/web/src/components/CommandPalette.logic.test.ts, plus the palette's key routing.
@MainActor
@Suite struct CommandPaletteTests {
    static let now = Double(1_792_713_600_000) // 2026-10-23
    static let day = 86_400_000.0

    func thread(_ id: String, _ title: String, project: String? = nil, activity: Double = now - 30 * day, opens: ThreadOpens? = nil,
                secondary: Bool = false) -> PaletteEntry {
        var entry = PaletteEntry(value: "thread:\(id)", searchTerms: [title], title: title, icon: .messageSquare, action: .run({}, keepOpen: false))
        entry.threadSearch = PaletteScoring.ThreadSearchSubject(id: id, title: title, projectTitle: project, activityAt: activity, opens: opens)
        entry.secondary = secondary
        return entry
    }

    func action(_ value: String, _ terms: [String], ran: (() -> Void)? = nil) -> PaletteEntry {
        PaletteEntry(value: value, searchTerms: terms, title: terms[0], icon: .squarePen, action: .run({ ran?() }, keepOpen: false))
    }

    func values(_ groups: [PaletteGroup]) -> [String] { groups.flatMap { $0.items.map(\.value) } }

    func labels(_ groups: [PaletteGroup]) -> [String] { groups.map(\.label) }

    func filter(_ query: String, actions: [PaletteEntry] = [], projects: [PaletteEntry] = [], settings: [PaletteEntry] = [],
                threads: [PaletteEntry] = [], messages: [PaletteEntry] = []) -> [PaletteGroup] {
        PaletteSearch.filter(actions.isEmpty ? [] : [PaletteGroup(value: "actions", label: "Actions", items: actions)], query: query,
                             isInSubmenu: false, projectItems: projects, settingsItems: settings, threadItems: threads,
                             threadMessageItems: messages, now: Self.now)
    }

    // CommandPalette.logic.test.ts:136-170.
    @Test func titleMatchesOutrankProjectMatches() {
        let items = [thread("context", "Fix navbar spacing", project: "Project"), thread("title", "Project kickoff notes", project: "Project")]
        let groups = filter("project", threads: items)
        #expect(groups.map(\.value) == ["threads-search"])
        #expect(values(groups) == ["thread:title", "thread:context"])
    }

    // CommandPalette.logic.test.ts:172-220.
    @Test func searchesSubmenuOptionsFromTheRoot() {
        let projects = [action("new-thread-in:t3code", ["t3code"]), action("new-thread-in:web", ["web"])]
        let page = PalettePage(addonIcon: .squarePen, groups: [PaletteGroup(value: "projects", label: "Projects", items: projects)])
        let newThreadIn = PaletteEntry(value: "action:new-thread-in", searchTerms: ["new thread"], title: "New thread in...",
                                       icon: .squarePen, action: .submenu(page))
        let root = [PaletteGroup(value: "actions", label: "Actions", items: [newThreadIn, action("action:add-project", ["Add project"])])]
        let threads = [thread("t", "Thread about t3code")]
        func search(_ query: String, _ inSubmenu: Bool) -> [[String]] {
            PaletteSearch.filter(inSubmenu ? page.groups : root, query: query, isInSubmenu: inSubmenu, rootGroups: root,
                                 projectItems: [], threadItems: threads, now: Self.now).map { [$0.label] + $0.items.map(\.title) }
        }
        #expect(search("new thread in t3code", false).first == ["Suggestions", "New thread in t3code"])
        #expect(!search("new thread", false).map { $0[0] }.contains("Suggestions"))
        #expect(search("t3", true) == [["Projects", "t3code"]])
        #expect(search("add project", true) == [["Actions", "Add project"]])
    }

    // CommandPalette.logic.test.ts:222-251.
    @Test func messageMatchesComeLastOnce() {
        let items = [thread("title", "Disable Convex schema validation"), thread("message", "Fix schema validation")]
        let pairs = { (m: [PaletteEntry]) in self.filter("convex", threads: items, messages: m).map { [$0.label] + $0.items.map(\.value) } }
        #expect(pairs([]) == [["Threads", "thread:title"]])
        #expect(pairs(items.reversed()) == [["Threads", "thread:title"], ["In messages", "thread:message"]])
    }

    // CommandPalette.logic.test.ts:253-293.
    @Test func activeThreadStaysFirstWhileItsTitleIsTyped() {
        let threads = [thread("t", "Compaction prompt timing and cache age", activity: Self.now - 12 * Self.day)]
        for query in ["comp", "compa", "compac", "compact", "compacti", "compaction"] {
            let groups = filter(query, actions: [action("action:copy", ["Copy thread ID"])],
                                settings: [action("setting:compact", ["Compact idle threads"]),
                                           PaletteEntry(value: "setting:providers", searchTerms: ["Providers", "compatibility"], title: "Providers",
                                                        icon: .settings, action: .run({}, keepOpen: false))],
                                threads: threads)
            #expect(groups.first?.label == "Threads", "\(query)")
        }
    }

    // CommandPalette.logic.test.ts:295-353.
    @Test func groupsOrderByTheirBestMatch() {
        let threads = [thread("t", "Upgrade to pnpm 12")]
        let upload = [action("action:upload", ["Upload file"])]
        #expect(labels(filter("upgrade", actions: upload, threads: threads)) == ["Threads"])
        #expect(labels(filter("upl", actions: upload, threads: threads)) == ["Actions"])
        let prs = PaletteEntry(value: "action:open-prs", searchTerms: ["Open pull requests", "pr", "prs", "review"], title: "Open pull requests",
                               icon: .gitPullRequestArrow, action: .run({}, keepOpen: false))
        #expect(values(filter("pr", actions: [prs, action("action:project", ["Project settings"])])) == ["action:open-prs", "action:project"])
        #expect(labels(filter("up", actions: upload, threads: threads)) == ["Actions", "Threads"])
        #expect(labels(filter("pnpm up", actions: upload, threads: threads)) == ["Threads"])
    }

    // CommandPalette.logic.test.ts:355-392.
    @Test func wholeCommandNameWinsAndOpenThreadGoesLast() {
        let threads = [thread("new", "New thread"), thread("open", "New thread layout", secondary: true), thread("other", "New thread button")]
        let groups = filter("new thread", actions: [action("action:new-thread", ["New thread in t3code"])], threads: threads)
        #expect(labels(groups) == ["Actions", "Threads"])
        #expect(groups.last?.items.last?.title == "New thread layout")
    }

    // CommandPalette.logic.test.ts:394-421.
    @Test func projectNamedForTheQueryOutranksThreads() {
        let threads = [thread("t", "Lakebed performance gains")]
        let projects = [action("project:lakebed", ["Lakebed", "/code/lakebed"])]
        #expect(labels(filter("lakebed", projects: projects, threads: threads)) == ["Projects", "Threads"])
        #expect(labels(filter("lake", projects: projects, threads: threads)) == ["Threads", "Projects"])
    }

    // CommandPalette.logic.test.ts:423-461.
    @Test func commandStaysAboveAThreadInDailyUse() {
        let threads = [thread("t", "New onboarding flow", activity: Self.now - Self.day,
                              opens: ThreadOpens(openedAt: Self.now - Self.day, score: 7))]
        #expect(labels(filter("new", actions: [action("action:new-thread", ["new thread", "chat"])], threads: threads)) == ["Actions", "Threads"])
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
            PaletteGroup(value: "recent-threads", label: "Recent Threads", items: [thread("t", "new thread ideas")]),
        ]
        let projects = [action("project:x", ["new project x"])]
        // Empty query: the root as is.
        #expect(PaletteSearch.filter(root, query: "", isInSubmenu: false, projectItems: projects, threadItems: []).map(\.value) == ["actions", "recent-threads"])
        // `>` keeps the actions group only.
        #expect(PaletteSearch.filter(root, query: ">", isInSubmenu: false, projectItems: projects, threadItems: []).map(\.value) == ["actions"])
        #expect(values(PaletteSearch.filter(root, query: ">new", isInSubmenu: false, projectItems: projects, threadItems: [])) == ["new"])
        // A query hides Recent Threads and adds the search groups.
        let searched = PaletteSearch.filter(root, query: "new", isInSubmenu: false, projectItems: projects, threadItems: [thread("t", "new thread ideas")])
        #expect(Set(searched.map(\.value)) == ["actions", "projects-search", "threads-search"])
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
