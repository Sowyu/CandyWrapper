import AppKit
import Testing
import DesignSystem
import T3Protocol
import T3Store
@testable import Features

/// WP7.9: the sidebar's selection, rename, hover card, empty state and Working shelf; the palette's
/// add-project paths, match highlights and route history; the icon picker and provider pill rules.
@MainActor
struct SidebarLeftoverTests {
    func content(_ snapshot: ShellSnapshot = SidebarPreview.richSnapshot()) -> SidebarContentView {
        let c = SidebarContentView()
        c.now = { SidebarPreview.referenceNow }
        c.setSnapshot(snapshot, animated: false)
        return c
    }

    func rows(_ c: SidebarContentView) -> [SidebarRowModel] { c.list.items.compactMap { if case .row(let r) = $0 { r } else { nil } } }

    // MARK: Selection (threadSelectionStore.ts)

    @Test func toggleAndRangeSelectFollowListOrder() {
        let c = content()
        c.toggleSelection(ThreadId("r3"))
        #expect(c.selectedThreadIds == [ThreadId("r3")] && c.selectionAnchor == ThreadId("r3"))
        c.selectRange(to: ThreadId("r5"))
        #expect(c.selectedThreadIds == [ThreadId("r3"), ThreadId("r4"), ThreadId("r5")])
        #expect(rows(c).filter(\.isSelected).map(\.id) == [ThreadId("r3"), ThreadId("r4"), ThreadId("r5")])
        // Toggling a selected row takes it out and keeps the anchor.
        c.toggleSelection(ThreadId("r4"))
        #expect(c.selectedThreadIds == [ThreadId("r3"), ThreadId("r5")])
        // A scope change drops the selection.
        c.setProjectScope("anything")
        #expect(c.selectedThreadIds.isEmpty && c.selectionAnchor == nil)
        // Without an anchor, Shift adds the row and anchors there.
        c.selectRange(to: ThreadId("r6"))
        #expect(c.selectedThreadIds == [ThreadId("r6")] && c.selectionAnchor == ThreadId("r6"))
        // A keyboard jump navigates like a click: the selection goes and the anchor moves (Sidebar.tsx:3144-3158).
        c.toggleSelection(ThreadId("r3"))
        c.navigated(to: ThreadId("r5"))
        #expect(c.selectedThreadIds.isEmpty && c.selectionAnchor == ThreadId("r5"))
    }

    // MARK: Rename

    @Test func renameLendsTheFieldToTheRow() throws {
        let c = content()
        c.frame = NSRect(x: 0, y: 0, width: 300, height: 1400)
        c.layoutSubtreeIfNeeded()
        c.startRename(ThreadId("r3"))
        #expect(c.renamingThreadId == ThreadId("r3"))
        let row = try #require(rows(c).first { $0.id == ThreadId("r3") })
        #expect(row.isRenaming)
        c.list.layoutSubtreeIfNeeded()
        let view = try #require(c.list.rowView("thread:r3"))
        #expect(c.list.renameField.superview === view)
        #expect(c.list.renameField.input.text == "Create a file named approval-demo.txt")
        var committed: (ThreadId, String, String)?
        c.actions.rename = { committed = ($0, $1, $2) }
        c.list.renameField.input.text = "Renamed"
        c.list.renameField.input.onSubmit?()
        #expect(committed?.0 == ThreadId("r3") && committed?.1 == "Renamed" && committed?.2 == "Create a file named approval-demo.txt")
        #expect(c.renamingThreadId == nil)
    }

    // MARK: Hover card (SidebarThreadTooltip)

    @Test func hoverCardShowsProjectBranchTerminalsAndProvider() throws {
        let c = content()
        c.state.environments = SidebarEnvironments(primaryId: nil, labels: [:], machines: [:])
        c.state.terminalProcesses = [ThreadId("r1"): 2]
        c.actions.hoverProvider = { _ in ("claudeAgent", "Claude Haiku 5.5", ["Codex"], nil) }
        let card = try #require(c.hoverCardModel(ThreadId("r1")))
        #expect(card.title == "Ship the sidebar virtualization")
        #expect(card.projectLabel == "candywrapper" && card.branch == "m3-skeleton")
        #expect(card.terminalProcessCount == 2 && card.handedOffFrom == ["Codex"] && card.provider?.label == "Claude Haiku 5.5")
        #expect(card.errorIsUsageLimit == nil)
        let view = SidebarThreadHoverCardView(card)
        #expect(view.popupSize.width <= 320 && view.popupSize.height > 60)
    }

    // MARK: Empty state, Working shelf

    @Test func noProjectsShowsTheAddProjectRow() {
        let c = content(SidebarPreview.snapshot(projects: [], threads: []))
        #expect(c.list.items == [.noProjects])
        var added = 0
        c.actions.addProject = { added += 1 }
        c.list.onAddProject?()
        #expect(added == 1)
    }

    @Test func workingShelfFoldsRunningThreadsUnderItsHeader() {
        let c = content()
        c.state.inboxReturns = SidebarInboxReturnTracker()
        c.state.workingShelfEnabled = true
        // r1 works too, but pins stay where the user put them.
        #expect(c.list.items.contains(.shelfHeader(.working, label: "Working (1)", expanded: false)))
        #expect(!rows(c).contains { $0.section == .working })
        c.state.workingExpanded = true
        let working = rows(c).filter { $0.section == .working }
        #expect(working.map(\.id) == [ThreadId("r6")] && working.allSatisfy { $0.variant == .card && $0.action == .settle })
    }

    // MARK: Palette

    @Test func browsePathsFollowT3() {
        typealias P = PaletteAddProjectPaths
        #expect(P.isBrowseQuery("~/") && P.isBrowseQuery("/Users") && P.isBrowseQuery("./a") && !P.isBrowseQuery("demo"))
        #expect(P.directoryPath("~/code/de") == "~/code/" && P.leafSegment("~/code/de") == "de")
        #expect(P.parentPath("/Users/mrm/") == "/Users/" && P.parentPath("/Users/") == "/" && P.parentPath("/") == nil)
        #expect(P.parentPath("~/code/") == "~/" && !P.canNavigateUp("~/code") && P.canNavigateUp("~/code/"))
        #expect(P.appendSegment("~/code/de", "demo") == "~/code/demo/")
        #expect(P.resolveForDispatch("../other/", cwd: "/w/project") == "/w/other")
        #expect(P.resolveForDispatch(" ~/x/ ", cwd: nil) == "~/x")
        #expect(P.inferTitle("/w/My App/") == "My App")
        let entries = [P.Entry(name: "demo", fullPath: "/s/demo"), P.Entry(name: ".git", fullPath: "/s/.git"), P.Entry(name: "Docs", fullPath: "/s/Docs")]
        #expect(P.filter(entries, query: "d").visible.map(\.name) == ["demo", "Docs"])
        #expect(P.filter(entries, query: ".").visible.map(\.name) == [".git"])
        #expect(P.filter(entries, query: "demo").exact?.fullPath == "/s/demo")
        #expect(P.newProjectFolderName("Pinball Stats!") == "pinball-stats" && P.newProjectFolderName("Café") == "cafe")
        #expect(P.newProjectFolderName("***") == "project" && P.newProjectFolderName("con") == "con-project")
        #expect(P.newProjectPathPreview(root: "/t3/projects", name: "My App") == "/t3/projects/my-app")
        #expect(P.cloneDirectoryName("https://github.com/acme/widgets.git") == "widgets")
        #expect(P.cloneDirectoryName("git@github.com:acme/widgets.git") == "widgets")
        #expect(P.cloneDirectoryName("https://host:8080") == "" && P.cloneDirectoryName("https://host/acme/123") == "123")
        #expect(P.normalizePastedCloneUrl("acme/widgets") == "https://github.com/acme/widgets.git")
        #expect(P.normalizePastedCloneUrl("https://gitlab.com/a/b") == "https://gitlab.com/a/b")
        #expect(P.cloneDestinationBrowsePath(directory: "~/code/", selected: "work", cloneName: "widgets") == "~/code/work/widgets")
        #expect(P.cloneDestinationBrowsePath(directory: "~/code/", selected: "widgets", cloneName: "widgets") == "~/code/widgets/")
    }

    @Test func matchLineHighlightsTheQueryAfterTheTag() {
        var entry = PaletteEntry(value: "t", searchTerms: [], title: "T", match: "Agent: Fix THE store", icon: .messageSquare,
                                 action: .run({}, keepOpen: false))
        entry.matchIsUser = false
        entry.matchQuery = " the "
        // "Agent: " is 7 UTF-16 units; "THE" sits at 4...6 of the snippet.
        #expect(entry.matchHighlights == [11, 12, 13])
        let item = CommandPaletteController.item(entry)
        #expect(item.matchIsUser == false && item.matchHighlights == [11, 12, 13])
    }

    @Test func settingsGroupJoinsTheSearch() {
        let setting = PaletteEntry(value: "setting:theme", searchTerms: ["Theme", "Appearance"], title: "Theme",
                                   description: "Settings \u{00B7} Appearance", icon: .settings, action: .run({}, keepOpen: false))
        let groups = PaletteSearch.filter([], query: "theme", isInSubmenu: false, projectItems: [], settingsItems: [setting], threadItems: [])
        #expect(groups.map(\.label) == ["Settings"])
    }

    @Test func routeHistoryMovesLikeABrowser() {
        let h = RouteHistory()
        var shown: [RouteHistory.Route] = []
        var gone: Set<String> = []
        h.apply = { route in
            if case .draft(let id) = route, gone.contains(id) { return false }
            shown.append(route)
            h.record(route) // applying a route fires the app's hooks; they must not record
            return true
        }
        h.record(.thread(ThreadId("a")))
        h.record(.thread(ThreadId("a")))
        h.record(.draft("d"))
        h.record(.settings(.general))
        #expect(h.entries.count == 3)
        #expect(h.back() && shown.last == .draft("d"))
        #expect(h.back() && shown.last == .thread(ThreadId("a")))
        #expect(!h.back())
        #expect(h.forward() && shown.last == .draft("d"))
        // A new route drops the forward entries.
        h.record(.usage)
        #expect(h.entries == [.thread(ThreadId("a")), .draft("d"), .usage])
        // A route that no longer exists is skipped and forgotten.
        gone.insert("d")
        #expect(h.back() && shown.last == .thread(ThreadId("a")))
        #expect(h.entries == [.thread(ThreadId("a")), .usage])
    }

    // MARK: Icon picker, provider pill

    @Test func iconPickerRules() {
        #expect(ProjectIconPickerDialog.filterIcons("").first == "folder-code")
        #expect(ProjectIconPickerDialog.filterIcons("git branch").contains("git-branch"))
        #expect(ProjectIconPickerDialog.filterIcons("zzzz").isEmpty)
        #expect(ProjectIconPickerDialog.isValidMonogram("T3") && ProjectIconPickerDialog.isValidMonogram("ÉA"))
        #expect(!ProjectIconPickerDialog.isValidMonogram("A B") && !ProjectIconPickerDialog.isValidMonogram("") && !ProjectIconPickerDialog.isValidMonogram("-A"))
        #expect(ProjectIconPickerDialog.firstEmoji(" 🚀 go") == "🚀")
        #expect(ProjectIconPickerDialog.firstEmoji("🇩🇪") == "🇩🇪")
        #expect(ProjectIconPickerDialog.firstEmoji("abc") == nil)
        #expect(ProjectIconPickerDialog.label("git-branch") == "Git Branch")
    }

    private func provider(_ driver: String, _ status: String?, finished: String? = nil, version: String? = nil, latest: String? = nil) -> ServerProvider {
        var p = ServerProvider(instanceId: ProviderInstanceId(driver), driver: driver)
        p.checkedAt = "2026-10-10T00:00:00.000Z"
        p.version = version
        p.latestVersion = latest
        p.updateState = status.map { ServerProvider.UpdateState(status: $0, finishedAt: finished) }
        return p
    }

    @Test func providerPillShowsRunningThenRecentResults() {
        let after = "2026-10-10T00:00:00.000Z"
        let running = SidebarProviderUpdatePillModel.resolve([provider("codex", "running")], visibleAfter: after, dismissed: [])
        #expect(running?.tone == .loading && running?.title == "Updating Codex")
        let two = SidebarProviderUpdatePillModel.resolve([provider("codex", "queued"), provider("claudeAgent", "running")], visibleAfter: after, dismissed: [])
        #expect(two?.title == "Updating 2 providers" && two?.description == "Codex and Claude updates are in progress.")
        let ok = SidebarProviderUpdatePillModel.resolve([provider("codex", "succeeded", finished: "2026-10-10T01:00:00.000Z", version: "1.2.0")],
                                                        visibleAfter: after, dismissed: [])
        #expect(ok?.tone == .success && ok?.title == "Codex updated: v1.2.0" && ok?.dismissAfterMs == 3000)
        let failed = SidebarProviderUpdatePillModel.resolve([provider("claudeAgent", "failed", finished: "2026-10-10T02:00:00.000Z", latest: "2.0.0")],
                                                            visibleAfter: after, dismissed: [])
        #expect(failed?.tone == .error && failed?.title == "Claude v2.0.0 update failed" && failed?.dismissible == true)
        // Results from before this client looked, and dismissed ones, stay hidden.
        #expect(SidebarProviderUpdatePillModel.resolve([provider("codex", "failed", finished: "2026-09-01T00:00:00.000Z")], visibleAfter: after, dismissed: []) == nil)
        #expect(SidebarProviderUpdatePillModel.resolve([provider("claudeAgent", "failed", finished: "2026-10-10T02:00:00.000Z", latest: "2.0.0")],
                                                       visibleAfter: after, dismissed: [failed!.key]) == nil)
    }

    /// T3 f15aa815f3: an update on a non-default instance shows past the default instance's idle or older state.
    @Test func providerPillSeesNonDefaultInstances() {
        let after = "2026-10-10T00:00:00.000Z"
        var work = provider("codex", "running")
        work.instanceId = ProviderInstanceId("codex-work")
        let running = SidebarProviderUpdatePillModel.resolve([provider("codex", nil), work], visibleAfter: after, dismissed: [])
        #expect(running?.tone == .loading && running?.title == "Updating Codex")
        var workFailed = provider("codex", "failed", finished: "2026-10-10T02:00:00.000Z")
        workFailed.instanceId = ProviderInstanceId("codex-work")
        let failed = SidebarProviderUpdatePillModel.resolve(
            [provider("codex", "succeeded", finished: "2026-10-10T01:00:00.000Z"), workFailed], visibleAfter: after, dismissed: [])
        #expect(failed?.tone == .error && failed?.title == "Codex update failed")
    }
}
