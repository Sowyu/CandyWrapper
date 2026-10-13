import AppKit
import Testing
import DesignSystem
import T3Protocol
import T3Store
@testable import Features

/// Search, project scope and draft rows against T3's rules (Sidebar.tsx, Sidebar.logic.ts).
@MainActor
struct SidebarSearchTests {
    let nowMs = TimestampFormat.nowMs(SidebarPreview.referenceNow)

    func content(_ snapshot: ShellSnapshot = SidebarPreview.richSnapshot()) -> SidebarContentView {
        let c = SidebarContentView()
        c.now = { SidebarPreview.referenceNow }
        c.setSnapshot(snapshot, animated: false)
        return c
    }

    func keys(_ c: SidebarContentView) -> [String] { c.list.items.map(\.key) }

    @Test func titleMatchesComeBeforeMessageMatchesInShelfOrder() {
        let snap = SidebarPreview.richSnapshot()
        let state = SidebarListState()
        // "the" hits the pinned r1 and r2, the active r6 and the settled r10 and r11 by title; r7 only
        // through the server's match, so it comes last.
        let match = ThreadSearchMatch(threadId: ThreadId("r7"), projectId: ProjectId("p3"), source: "assistant", snippet: "THE test")
        let items = SidebarListBuilder.searchItems(snapshot: snap, state: state, query: " the ", matches: [match], pending: false,
                                                   highlighted: 0, nowMs: nowMs)
        let results = items.compactMap { if case .searchResult(let r) = $0 { r } else { nil } }
        #expect(Set(results.prefix(2).map(\.id.rawValue)) == ["r1", "r2"])
        #expect(results.suffix(4).map(\.id.rawValue) == ["r6", "r10", "r11", "r7"])
        #expect(results.first?.isHighlighted == true && results.last?.match == match)
        #expect(results.map(\.index) == Array(0..<6))
        #expect(items.last?.height == 44 && items.first?.height == 36)
    }

    @Test func emptyResultsSayWhetherTheServerIsStillSearching() {
        let snap = SidebarPreview.richSnapshot()
        let pending = SidebarListBuilder.searchItems(snapshot: snap, state: SidebarListState(), query: "zzz", matches: [], pending: true,
                                                     highlighted: 0, nowMs: nowMs)
        #expect(pending == [.emptyText("Searching thread messages\u{2026}", search: true)])
        let done = SidebarListBuilder.searchItems(snapshot: snap, state: SidebarListState(), query: "zzz", matches: [], pending: false,
                                                  highlighted: 0, nowMs: nowMs)
        #expect(done == [.emptyText("No threads found", search: true)])
    }

    @Test func pullRequestTermsMatch() {
        let snap = SidebarPreview.snapshot(projects: [SidebarPreview.project("p", "demo")], threads: [
            SidebarPreview.thread("a", "Plain", project: "p", kind: .read, minutesAgo: 3, extra: [
                "linkedPullRequest": ["projectId": "p", "repository": "acme/app", "number": 42, "url": "https://github.com/acme/app/pull/42"]]),
            SidebarPreview.thread("b", "Other", project: "p", kind: .read, minutesAgo: 4),
        ])
        let threads = snap.threads.map(SidebarThread.init)
        #expect(SidebarModel.searchSidebarThreads(threads, query: "#42").map(\.id.rawValue) == ["a"])
        #expect(SidebarModel.searchSidebarThreads(threads, query: "ACME/app#4").map(\.id.rawValue) == ["a"])
        #expect(SidebarModel.searchSidebarThreads(threads, query: "   ").isEmpty)
    }

    @Test func excerptHighlightsFoldOnlyAsciiCase() {
        let text = "Ship THE thing, and the rest"
        let ranges = SearchExcerptView.highlights(in: text, query: " the ")
        #expect(ranges.map { String(text[$0]) } == ["THE", "the"])
        #expect(SearchExcerptView.highlights(in: "Äpfel äpfel", query: "äpfel").count == 1)
    }

    @Test func keyboardWrapsOpensAndEscapeClears() {
        let c = content()
        var opened: ThreadId?
        c.actions.openThread = { opened = $0 }
        c.setSearchText("the")
        #expect(c.isSearching && keys(c).count == 5)
        #expect(c.searchCommand(#selector(NSResponder.moveUp(_:))))
        #expect(c.searchHighlight == 4) // wrapped to the last of five title matches
        #expect(c.searchCommand(#selector(NSResponder.moveDown(_:))))
        #expect(c.searchHighlight == 0)
        c.setSearchHighlight(2, scroll: false)
        #expect(c.searchCommand(#selector(NSResponder.insertNewline(_:))))
        #expect(opened == ThreadId("r6") && !c.isSearching && c.state.activeThreadId == ThreadId("r6"))
        #expect(!keys(c).contains { $0.hasPrefix("search:") })
        c.setSearchText("rename")
        #expect(c.searchCommand(#selector(NSResponder.cancelOperation(_:))))
        #expect(!c.isSearching && c.search.text.isEmpty)
        // Not searching: Escape is left to the field.
        #expect(!c.searchCommand(#selector(NSResponder.cancelOperation(_:))))
    }

    @Test func serverMatchesArriveAfterTheDebounce() async throws {
        let c = content()
        var queries: [String] = []
        c.actions.searchThreads = { q in
            queries.append(q)
            return [ThreadSearchMatch(threadId: ThreadId("r10"), projectId: ProjectId("p2"), source: "user", snippet: "the store actor")]
        }
        c.setSearchText("x")
        c.setSearchText("xy")
        c.setSearchText("xyz")
        #expect(c.list.items == [.emptyText("Searching thread messages\u{2026}", search: true)])
        // The main actor is shared with other suites; wait up to 3 s for the 200 ms debounce.
        for _ in 0..<60 where queries.isEmpty || keys(c) != ["search:r10"] { try await Task.sleep(for: .milliseconds(50)) }
        #expect(queries == ["xyz"])
        #expect(keys(c) == ["search:r10"])
    }

    @Test func scopeFiltersListSearchAndEmptyState() {
        let c = content()
        let groups = SidebarListBuilder.projectScopeGroups(snapshot: c.snapshot)
        let t3 = try! #require(groups.first { $0.label == "t3code" })
        c.setProjectScope(t3.key)
        #expect(Set(keys(c).filter { $0.hasPrefix("thread:") }) == ["thread:r2", "thread:r7"])
        #expect(c.filterButton.icon == nil && !c.filterMonogram.isHidden)
        c.setSearchText("rename") // r10 lives in candywrapper
        #expect(keys(c) == ["empty"])
        c.clearSearch()
        // A key whose group is gone scopes nothing.
        c.setProjectScope("gone")
        #expect(keys(c).contains("thread:r3") && c.filterButton.icon == .folder)
        // A scoped project without threads.
        let empty = content(SidebarPreview.snapshot(projects: [SidebarPreview.project("p1", "demo-repo"), SidebarPreview.project("p9", "lonely")],
                                                    threads: [SidebarPreview.thread("x", "X", project: "p1", kind: .read, minutesAgo: 2)]))
        let lonely = SidebarListBuilder.projectScopeGroups(snapshot: empty.snapshot).first { $0.label == "lonely" }!
        empty.setProjectScope(lonely.key)
        #expect(empty.list.items == [.emptyText("No threads in lonely yet", search: false)])
    }

    @Test func scopePersists() {
        let suite = "candywrapper.tests.scope.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let c = content()
        c.scopeDefaults = defaults
        c.setProjectScope("k")
        let d = content()
        d.scopeDefaults = defaults
        #expect(d.state.projectScopeKey == "k")
        c.setProjectScope(nil)
        #expect(defaults.string(forKey: SidebarContentView.scopeDefaultsKey) == nil)
        defaults.removePersistentDomain(forName: suite)
    }

    @Test func scopePopupFiltersAndPicks() {
        let groups = SidebarListBuilder.projectScopeGroups(snapshot: SidebarPreview.richSnapshot())
        let view = SidebarProjectScopeView(groups: groups, selectedKey: nil, minimumWidth: 150)
        #expect(view.shown.map(\.label) == ["All projects", "candywrapper", "demo-repo", "t3code"])
        var picked: String?? = .none
        view.onSelect = { picked = .some($0) }
        view.setQuery("REPO")
        #expect(view.shown.map(\.label) == ["demo-repo"] && view.highlighted == 0)
        #expect(view.handleKey(.enter))
        #expect(picked == .some(groups.first { $0.label == "demo-repo" }!.key))
        view.setQuery("nothing")
        #expect(view.shown.isEmpty && view.highlighted == nil)
        view.setQuery("")
        #expect(view.shown.count == 4 && view.highlighted == nil)
        #expect(view.handleKey(.up) && view.highlighted == 3)
        #expect(view.naturalSize.width >= 148 && view.naturalSize.width <= 286)
    }

    /// The draft screen's picker (DraftHeroHeadline.tsx:184-200 in 2994): projects then "Add project", which filtering
    /// drops and which is never the selection.
    @Test func draftProjectPickerFiltersAndTrailsAddProject() {
        let groups = SidebarListBuilder.projectScopeGroups(snapshot: SidebarPreview.richSnapshot())
        let demo = groups.first { $0.label == "demo-repo" }!.key
        let view = SidebarProjectScopeView(groups: groups, selectedKey: demo, minimumWidth: 288, extra: .addProject)
        #expect(view.shown.map(\.label) == ["candywrapper", "demo-repo", "t3code", "Add project"])
        #expect(view.selectedKey == demo)
        var picked: String?? = .none
        view.onSelect = { picked = .some($0) }
        view.setQuery("t3")
        #expect(view.shown.map(\.label) == ["t3code"] && view.highlighted == 0)
        view.setQuery("add")
        #expect(view.shown.isEmpty)
        view.setQuery("")
        #expect(view.handleKey(.up) && view.highlighted == 3)
        #expect(view.handleKey(.enter) && picked == .some(nil))
        #expect(view.naturalSize.width == 286)
    }

    @Test func draftRowsLeadTheListAndFreezeWhileOpen() {
        let c = content()
        let created = SidebarPreview.referenceNow
        let a = SidebarDraft(id: "d1", projectId: ProjectId("p1"), prompt: "  first line\nsecond", createdAt: created)
        let b = SidebarDraft(id: "d2", projectId: ProjectId("p3"), prompt: "newer", createdAt: created.addingTimeInterval(60))
        let empty = SidebarDraft(id: "d3", projectId: ProjectId("p2"), prompt: "   ", createdAt: created)
        c.setDrafts([a, b, empty], activeDraftId: nil)
        #expect(Array(keys(c).prefix(3)) == ["draft:d2", "draft:d1", "draft-divider"])
        if case .draft(let row) = c.list.items[1] {
            #expect(row.preview == "first line" && row.projectLabel == "demo-repo" && !row.isActive)
        }
        // Opening d1 freezes its row as it was; typing does not repaint it.
        c.setDrafts([a, b], activeDraftId: "d1")
        var typed = a
        typed.prompt = "first line edited"
        c.setDrafts([typed, b], activeDraftId: "d1")
        if case .draft(let row) = c.list.items[1] { #expect(row.preview == "first line" && row.isActive) }
        // A draft opened empty has no row until it is left.
        let fresh = SidebarDraft(id: "d4", projectId: ProjectId("p2"), prompt: "", createdAt: created)
        c.setDrafts([a, b, fresh], activeDraftId: "d4")
        var typedFresh = fresh
        typedFresh.prompt = "hello"
        c.setDrafts([a, b, typedFresh], activeDraftId: "d4")
        #expect(!keys(c).contains("draft:d4"))
        c.setDrafts([a, b, typedFresh], activeDraftId: nil)
        #expect(keys(c).contains("draft:d4"))
        // Scope hides drafts of other projects; no drafts, no divider.
        c.setProjectScope(SidebarListBuilder.projectScopeGroups(snapshot: c.snapshot).first { $0.label == "candywrapper" }!.key)
        #expect(keys(c).first == "draft:d4")
        c.setDrafts([], activeDraftId: nil)
        #expect(!keys(c).contains("draft-divider"))
    }

    @Test func draftClicksOpenAndDiscard() {
        let c = content()
        var opened: String?, discarded: String?
        c.actions.openDraft = { opened = $0 }
        c.actions.discardDraft = { discarded = $0 }
        c.setDrafts([SidebarDraft(id: "d1", projectId: ProjectId("p1"), prompt: "x", createdAt: Date())], activeDraftId: nil)
        let row = SidebarDraftRowView()
        c.list.onOpenDraft?("d1")
        row.onDiscard = c.list.onDiscardDraft
        row.configure(c.list.items[0])
        row.discardButton.performAction()
        #expect(opened == "d1" && discarded == "d1")
    }
}
