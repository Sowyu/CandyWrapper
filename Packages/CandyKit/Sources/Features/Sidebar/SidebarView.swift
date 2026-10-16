import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// What the sidebar asks the app to do. Server commands live in the app; the sidebar only calls these.
@MainActor
public struct SidebarActions {
    public var openThread: (ThreadId) -> Void = { _ in }
    public var settle: (ThreadId) -> Void = { _ in }
    public var unsettle: (ThreadId) -> Void = { _ in }
    public var snooze: (ThreadId, NSView) -> Void = { _, _ in }
    public var unsnooze: (ThreadId) -> Void = { _ in }
    public var unpin: (ThreadId) -> Void = { _ in }
    /// A row's Woke pill was clicked (`useAcknowledgeThreadWoke`).
    public var acknowledgeWake: (ThreadId) -> Void = { _ in }
    /// A row's pull request badge was clicked.
    public var openPullRequest: (ThreadId) -> Void = { _ in }
    /// A pull request row in the badge's hover list: open the thread and that pull request in its panel
    /// (`handlePrClick` with a target URL, Sidebar.tsx:1557-1567).
    public var openPullRequestURL: (ThreadId, String) -> Void = { _, _ in }
    /// Right click on a thread row: the row view and the event, for the native menu.
    public var contextMenu: (ThreadId, NSEvent, NSView) -> Void = { _, _, _ in }
    /// The undo notice's button (`undoLatestThreadAction`).
    public var undo: () -> Void = {}
    /// The footer's Back on a utility page (SidebarChrome.tsx:203-210).
    public var back: () -> Void = {}
    /// The brand, a link to "/" (SidebarChrome.tsx:110-123): the index route's draft landing.
    public var goHome: () -> Void = {}
    public var toggleSidebar: () -> Void = {}
    /// `orchestration.searchThreads {query}`; nil when the request failed or there is no connection, which
    /// leaves title search on its own (threadSearch.ts:58-62).
    public var searchThreads: (String) async -> [ThreadSearchMatch]? = { _ in nil }
    /// Opens a new-thread draft (`/draft/$draftId`, Sidebar.tsx:3188-3201).
    public var openDraft: (String) -> Void = { _ in }
    /// `discardComposerDraft` from a draft row's x.
    public var discardDraft: (String) -> Void = { _ in }
    /// The scope popup's settings button and context menu (`/projects/$projectKey`), with the group key.
    public var openProjectSettings: (String) -> Void = { _ in }
    public var addProject: () -> Void = {}
    public var newThread: () -> Void = {}
    public var openSettings: () -> Void = {}
    public var openPullRequests: () -> Void = {}
    public var openUsage: () -> Void = {}
    /// Files dropped on a thread row (`handleThreadFileDrop`): open the thread and attach them there.
    public var dropFiles: (ThreadId, [URL]) -> Void = { _, _ in }
    /// The inline rename committed: thread, typed title, title before (`commitThreadRename`).
    public var rename: (ThreadId, String, String) -> Void = { _, _, _ in }
    /// The hover card's provider row and handoff line, from the environment's provider list: the glyph's
    /// driver, the model label (with the instance name when instances need telling apart) and the names of
    /// earlier providers. Nil when the provider is unknown.
    /// The accent is set only when the instance shows a badge (`showInstanceBadge && accentColor`).
    public var hoverProvider: (ThreadShell) -> (driver: String, label: String, handedOffFrom: [String], accent: String?)? = { _ in nil }
    /// The branch a checkout (environment, cwd) is on now, from its VCS status; nil until known. The app starts
    /// watching the checkout on the first ask and calls `checkoutBranchChanged()` when it learns more.
    public var checkoutBranch: (_ environmentId: String, _ cwd: String) -> String? = { _, _ in nil }
    public init() {}
}

/// The thread sidebar's content (`ThreadSidebar`, Sidebar.tsx:4960-5581): the titlebar row with the brand,
/// the fixed search header, the virtualized thread list and the utility footer. It goes inside
/// `SidebarContainerView.content`.
public final class SidebarContentView: DSView {
    public let list = SidebarListView()
    public let scrollArea: ScrollAreaView
    public let trigger = SidebarTriggerView()
    let backdrop = StageBackdropView()
    private let environmentPill = BadgeView("Nightly", variant: .secondary, size: .sm)
    let brand = SidebarBrandView()
    let search = SidebarSearchFieldView()
    let filterButton = SidebarContentView.headerButton(.listFilter, "Filter threads by project")
    let addProjectButton = SidebarContentView.headerButton(.folderPlus, "Add project")
    let newThreadButton = SidebarContentView.headerButton(.squarePen, "New thread")
    let settingsButton = SidebarContentView.footerButton(.settings, "Settings")
    let pullRequestsButton = SidebarContentView.footerButton(.gitPullRequestArrow, "Pull Requests")
    let usageButton = SidebarContentView.footerButton(.chartNoAxesColumn, "Usage")
    let backButton = SidebarMenuButtonView("Back", icon: .arrowLeft)
    let undoNotice = SidebarUndoNoticeView()
    /// `SidebarProviderUpdatePill` between the undo notice and the utility buttons.
    public let providerUpdatePill = SidebarProviderUpdatePillView()
    /// `SidebarUpdatePill` at the end of the utility row (SidebarChrome.tsx:234). T3 renders it only in the
    /// desktop app (SidebarUpdatePill.tsx:111-113); hidden until the app shows it.
    public let updatePill = SidebarUpdatePillView()

    public var actions = SidebarActions() { didSet { wireActions() } }
    public private(set) var snapshot: ShellSnapshot?
    public var state = SidebarListState() {
        didSet {
            // Inline, so the fix-up does not run this observer again.
            if isOnUtilityPage { state.activeThreadId = nil; state.activeDraftId = nil }
            if state != oldValue { rebuild(animated: true) }
        }
    }
    /// Where the shelves' expansion persists, as T3's `t3code:sidebar:*-expanded` localStorage keys
    /// (Sidebar.tsx:297-301). Nil in tests and previews; the app sets it once, which restores them.
    public var shelfDefaults: UserDefaults? {
        didSet {
            guard let d = shelfDefaults else { return }
            state.settledExpanded = d.bool(forKey: Self.settledExpandedKey)
            state.snoozedExpanded = d.bool(forKey: Self.snoozedExpandedKey)
            state.workingExpanded = d.bool(forKey: Self.workingExpandedKey)
        }
    }
    static let settledExpandedKey = "sidebar.settledExpanded"
    static let snoozedExpandedKey = "sidebar.snoozedExpanded"
    static let workingExpandedKey = "sidebar.workingExpanded"

    func toggleShelf(_ shelf: SidebarShelf) {
        switch shelf {
        case .settled: state.settledExpanded.toggle(); state.settledVisibleCount = SidebarListBuilder.settledInitialCount
        case .snoozed: state.snoozedExpanded.toggle()
        case .working: state.workingExpanded.toggle()
        }
        saveShelves()
    }

    private func saveShelves() {
        guard let d = shelfDefaults else { return }
        d.set(state.settledExpanded, forKey: Self.settledExpandedKey)
        d.set(state.snoozedExpanded, forKey: Self.snoozedExpandedKey)
        d.set(state.workingExpanded, forKey: Self.workingExpandedKey)
    }

    /// Traffic lights: the brand and toggle sit after `--workspace-controls-left` (90px) on windowed macOS.
    public var windowedMac = true { didSet { needsLayout = true } }
    public var stage: SidebarStage = .nightly { didSet { applyStage() } }
    /// The items the sidebar shows, in builder order: what Settle's forward navigation and the menus walk.
    public var shownItems: [SidebarItem] { list.items }
    public var showsPullRequests = true { didSet { needsLayout = true } }
    /// On Pull Requests or Usage the footer shows only Back (`isSidebarUtilityPage`).
    /// Those pages have no route thread or draft, so no row is active (Sidebar.tsx:2490-2494), whoever sets one.
    public var isOnUtilityPage = false { didSet { if isOnUtilityPage { clearActiveRows() }; needsLayout = true } }

    private func clearActiveRows() {
        if state.activeThreadId != nil { state.activeThreadId = nil }
        if state.activeDraftId != nil { state.activeDraftId = nil }
    }
    /// "Settled 2 threads," with its undo button; nil hides the notice.
    public var undoNoticeText: String? {
        didSet {
            undoNotice.text = undoNoticeText ?? ""
            undoNotice.isHidden = undoNoticeText == nil
            needsLayout = true
        }
    }
    /// The undo button's label, `⌘Z to undo` when `thread.undo` has a shortcut.
    public var undoShortcut: String? = "⌘Z" { didSet { undoNotice.shortcut = undoShortcut } }
    /// The clock, injectable for tests and previews.
    public var now: () -> Date = Date.init


    /// The scope trigger shows the scoped project's favicon in place of the folder (SidebarThreadHeader.tsx:5).
    let filterMonogram = ProjectMonogramView()
    /// Where the project scope persists, as T3's persisted UI store does. Nil in tests and previews.
    public var scopeDefaults: UserDefaults? {
        didSet { state.projectScopeKey = scopeDefaults?.string(forKey: Self.scopeDefaultsKey) }
    }
    static let scopeDefaultsKey = "sidebar.projectScopeKey"
    private var scopePopup: OpenPopup?

    /// The search field's text. Searching starts at one non-blank character (Sidebar.tsx:2896).
    public private(set) var searchQuery = ""
    public var isSearching: Bool { !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// `activeSearchResultIndex`.
    public private(set) var searchHighlight = 0
    private var searchMatches: [ThreadSearchMatch] = []
    private var searchPending = false
    private var searchTask: Task<Void, Never>?
    private var searchOrderKey = ""
    /// The open draft as it was when it opened (`frozenActive`, Sidebar.tsx:972-995).
    private var frozenDraft: (id: String?, draft: SidebarDraft?) = (nil, nil)

    public override init(frame frameRect: NSRect) {
        scrollArea = ScrollAreaView(documentView: list, scrollFade: true)
        super.init(frame: frameRect)
        scrollArea.fadeSize = 12
        scrollArea.hideScrollbars = true
        addSubview(backdrop)
        addSubview(environmentPill)
        ClientSettingsStore.shared.observe { [weak self] keys in
            if keys.contains("environmentIdentificationMode") { self?.applyStage() }
        }
        addSubview(scrollArea)
        addSubview(brand)
        addSubview(trigger)
        undoNotice.isHidden = true
        undoNotice.shortcut = undoShortcut
        backButton.isHidden = true
        for v in [search, filterButton, addProjectButton, newThreadButton, settingsButton, pullRequestsButton, usageButton,
                  backButton, undoNotice, providerUpdatePill, updatePill] as [NSView] {
            addSubview(v)
        }
        updatePill.isHidden = true
        providerUpdatePill.onVisibilityChange = { [weak self] in self?.needsLayout = true }
        list.registerForDraggedTypes([.fileURL, .sidebarThreads])
        list.onVisibleRowsChange = { [weak self] in self?.scheduleLabelTimer() }
        list.onToggleShelf = { [weak self] in self?.toggleShelf($0) }
        list.sortContextProvider = { [weak self] in
            guard let self else { return SidebarSortPlanner.Context() }
            let snoozed = self.snapshot.map {
                SidebarListBuilder.Context(snapshot: $0, state: self.state, nowMs: self.nowMs).shelves.snoozed.count
            } ?? 0
            return SidebarSortPlanner.Context(settledExpanded: self.state.settledExpanded, settledVisibleCount: self.state.settledVisibleCount,
                                              routeThreadId: self.state.activeThreadId, snoozedCount: snoozed,
                                              activeTimeOrdered: self.state.workingShelfEnabled)
        }
        list.onShowMore = { [weak self] in self?.state.settledVisibleCount += SidebarListBuilder.settledPageCount }
        list.onHighlightSearchResult = { [weak self] i in self?.setSearchHighlight(i, scroll: false) }
        list.onOpenSearchResult = { [weak self] id in self?.selectSearchResult(id) }
        filterButton.addSubview(filterMonogram)
        filterMonogram.isHidden = true
        search.onChange = { [weak self] in self?.setSearchQuery($0) }
        search.onCommand = { [weak self] in self?.searchCommand($0) ?? false }
        setAccessibilityRole(.group)
        setAccessibilityLabel("Threads")
        applyStage()
        wireActions()
        // Project grouping follows the client settings everywhere projects are grouped.
        applyClientSettings(ClientSettingsStore.shared.current)
        clientSettingsObserver = ClientSettingsStore.shared.observe { [weak self] keys in
            guard keys.contains("sidebarProjectGroupingMode") || keys.contains("sidebarProjectGroupingOverrides")
                    || keys.contains("sidebarWorkingShelfEnabled") else { return }
            self?.applyClientSettings(ClientSettingsStore.shared.current)
        }
    }

    private var clientSettingsObserver: Int?

    /// `selectProjectGroupingSettings`.
    static func projectGrouping(_ c: ClientSettings) -> SidebarModel.ProjectGrouping {
        let overrides = (c["sidebarProjectGroupingOverrides"].objectValue ?? [:]).compactMapValues {
            $0.stringValue.flatMap(SidebarModel.ProjectGroupingMode.init(rawValue:))
        }
        return SidebarModel.ProjectGrouping(mode: SidebarModel.ProjectGroupingMode(rawValue: c.string("sidebarProjectGroupingMode")) ?? .repository,
                                            overrides: overrides)
    }

    private func applyClientSettings(_ c: ClientSettings) {
        let grouping = Self.projectGrouping(c)
        SidebarModel.ProjectGrouping.current = grouping
        if state.grouping != grouping { state.grouping = grouping }
        let working = c.bool("sidebarWorkingShelfEnabled")
        if state.workingShelfEnabled != working {
            // Off resets the tracker; on starts from a fresh baseline (`inboxReturns.observe(null)`).
            state.inboxReturns = working ? SidebarInboxReturnTracker() : nil
            state.workingShelfEnabled = working
        }
    }

    static func headerButton(_ icon: IconName, _ label: String) -> SidebarMenuButtonView {
        let b = SidebarMenuButtonView("", icon: icon, size: .icon)
        b.setAccessibilityLabel(label)
        b.toolTip = label
        return b
    }

    static func footerButton(_ icon: IconName, _ label: String) -> SidebarMenuButtonView { headerButton(icon, label) }

    private func applyStage() {
        let mode = ClientSettingsStore.shared.current.string("environmentIdentificationMode")
        let artwork = mode == "artwork" && stage == .nightly
        backdrop.isHidden = !artwork
        brand.onBackdrop = artwork
        trigger.mediaTint = artwork ? StageBackdropView.ink() : nil
        environmentPill.title = stage == .dev ? "Dev" : "Nightly"
        environmentPill.isHidden = mode != "pill" || stage == .none
        needsLayout = true
    }

    private func wireActions() {
        list.onOpen = { [weak self] id in self?.rowClicked(id) }
        list.lazyRenameField.configure { [weak self] field in
            field.onCommit = { [weak self] id, title, original in
                guard let self else { return }
                self.endRename()
                self.actions.rename(id, title, original)
            }
            field.onCancel = { [weak self] in self?.endRename() }
        }
        // Rows keep these closures across reuse, so they read `actions` when they fire.
        list.rowActions = SidebarRowActions(
            settle: { [weak self] in self?.actions.settle($0) }, unsettle: { [weak self] in self?.actions.unsettle($0) },
            snooze: { [weak self] in self?.actions.snooze($0, $1) }, unsnooze: { [weak self] in self?.actions.unsnooze($0) },
            unpin: { [weak self] in self?.actions.unpin($0) }, acknowledgeWake: { [weak self] in self?.actions.acknowledgeWake($0) },
            pullRequest: { [weak self] in self?.actions.openPullRequest($0) },
            pullRequestURL: { [weak self] in self?.actions.openPullRequestURL($0, $1) },
            contextMenu: { [weak self] in self?.actions.contextMenu($0, $1, $2) })
        undoNotice.onUndo = { [weak self] in self?.actions.undo() }
        backButton.action = { [weak self] in self?.actions.back() }
        brand.action = { [weak self] in self?.actions.goHome() }
        list.onOpenDraft = { [weak self] id in self?.actions.openDraft(id) }
        list.onAddProject = { [weak self] in self?.actions.addProject() }
        list.onFileDrop = { [weak self] id, urls in self?.actions.dropFiles(id, urls) }
        list.hoverCard = { [weak self] id in self?.hoverCardModel(id) }
        list.onDiscardDraft = { [weak self] id in self?.actions.discardDraft(id) }
        trigger.action = { [weak self] in self?.actions.toggleSidebar() }
        filterButton.action = { [weak self] in self?.toggleScopePopup() }
        addProjectButton.action = { [weak self] in self?.actions.addProject() }
        newThreadButton.action = { [weak self] in self?.actions.newThread() }
        settingsButton.action = { [weak self] in self?.actions.openSettings() }
        pullRequestsButton.action = { [weak self] in self?.actions.openPullRequests() }
        usageButton.action = { [weak self] in self?.actions.openUsage() }
    }

    // MARK: Data

    /// Shows a snapshot. Unchanged rows keep their views; only rows whose derived model differs reconfigure.
    /// `changedThreadIds` names the only threads that differ from the previous snapshot, when the caller
    /// knows; without it every thread is compared.
    public func setSnapshot(_ snapshot: ShellSnapshot?, animated: Bool = true, changedThreadIds: Set<ThreadId>? = nil) {
        self.snapshot = snapshot
        listCache?.noteChanges(changedThreadIds)
        rebuild(animated: animated)
    }

    /// Applies one coalesced store update. An empty change set does nothing.
    public func apply(_ update: ShellUpdate) {
        guard !update.changes.isEmpty || snapshot == nil else { return }
        setSnapshot(update.snapshot)
    }

    /// Drains the store, for the app to call from the store's `onChange` hop to the main actor.
    public func pull(from store: ShellStore) async {
        if let update = await store.takeUpdate() { apply(update) }
    }

    var nowMs: Int64 { TimestampFormat.nowMs(now()) }

    /// The thread rows in display order, outside search (`orderedThreadKeys`, Sidebar.tsx:3073-3079):
    /// what `thread.previous`, `thread.next` and `thread.jump.N` walk.
    public var orderedThreadIds: [ThreadId] {
        SidebarListBuilder.items(snapshot: snapshot, state: state, nowMs: nowMs, cache: listCache).compactMap {
            if case .row(let row) = $0 { row.id } else { nil }
        }
    }

    /// Keeps the list's threads, shelves and row models between rebuilds.
    public let listCache: SidebarListCache? = SidebarContentView.timing == "nocache" ? nil : SidebarListCache()

    /// Development: with CANDY_SIDEBAR_TIMING set, each rebuild prints its time to stderr; set to `nocache`,
    /// the list builds from scratch every time, as it did before `SidebarListCache`.
    private static let timing = ProcessInfo.processInfo.environment["CANDY_SIDEBAR_TIMING"]

    func rebuild(animated: Bool) {
        guard Self.timing != nil else { return rebuildNow(animated: animated) }
        let start = DispatchTime.now().uptimeNanoseconds, built = listCache?.rowModelBuilds ?? 0
        rebuildNow(animated: animated)
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        FileHandle.standardError.write(Data(String(format: "sidebar rebuild %.2f ms, %d items, %d rows built\n", ms, list.items.count,
                                                   (listCache?.rowModelBuilds ?? 0) - built).utf8))
    }

    private func rebuildNow(animated: Bool) {
        let ms = nowMs
        list.nowMs = ms
        // `inboxReturns.observe(workingShelfEnabled ? threads : null)` on every list rebuild.
        if let tracker = state.inboxReturns, let snapshot {
            tracker.observe(snapshot.threads.filter { $0.archivedAt == nil && $0.deletedAt == nil }.map(SidebarThread.init), nowMs: ms)
        }
        if isSearching {
            var items = searchItems(nowMs: ms)
            // A new result order puts the highlight back on the first result (Sidebar.tsx:2924-2930).
            let order = items.map(\.key).joined(separator: "\0")
            if order != searchOrderKey {
                searchOrderKey = order
                if searchHighlight != 0 { searchHighlight = 0; items = searchItems(nowMs: ms) }
            }
            list.setItems(items, animated: false, generation: nil)
        } else {
            searchOrderKey = ""
            // A thread changed in place or a label stepped: patch those rows of the list it already shows.
            var patched = false
            if let cache = listCache, let snapshot, list.itemsGeneration == cache.generation,
               let patch = cache.patch(snapshot: snapshot, state: state, nowMs: ms) {
                patched = list.patchItems(patch)
            }
            if !patched {
                let items = SidebarListBuilder.items(snapshot: snapshot, state: state, nowMs: ms, cache: listCache)
                list.setItems(items, animated: animated, generation: listCache?.generation)
            }
        }
        // The results `ul` is a listbox named "Thread search results" (Sidebar.tsx:5151-5156).
        list.setAccessibilityLabel(isSearching ? "Thread search results" : nil)
        updateScopeTrigger()
        scheduleLabelTimer()
    }

    private func searchItems(nowMs: Int64) -> [SidebarItem] {
        SidebarListBuilder.searchItems(snapshot: snapshot, state: state, query: searchQuery, matches: searchMatches,
                                       pending: searchPending, highlighted: searchHighlight, nowMs: nowMs)
    }

    // MARK: Search (Sidebar.tsx:2893-2937, 3203-3250)

    /// Types into the search field programmatically (tests, previews).
    public func setSearchText(_ query: String) {
        search.text = query
        setSearchQuery(query)
    }

    func setSearchQuery(_ query: String) {
        searchQuery = query
        searchHighlight = 0
        searchTask?.cancel()
        searchMatches = []
        // `useThreadSearch`: the server search waits for a settled query of two or more characters.
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchPending = q.count >= SidebarModel.threadSearchMinLength
        if searchPending {
            searchTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(SidebarModel.threadSearchDebounceMs))
                guard !Task.isCancelled, let search = self?.actions.searchThreads else { return }
                let matches = await search(q)
                guard !Task.isCancelled, let self,
                      self.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == q else { return }
                self.searchMatches = matches ?? []
                self.searchPending = false
                self.rebuild(animated: false)
            }
        }
        // The results list replaces the thread list outright; neither slides.
        rebuild(animated: false)
    }

    public func clearSearch() {
        search.text = ""
        setSearchQuery("")
    }

    func setSearchHighlight(_ index: Int, scroll: Bool) {
        guard isSearching, index != searchHighlight else { return }
        searchHighlight = index
        rebuild(animated: false)
        if scroll, let item = list.items.first(where: { if case .searchResult(let r) = $0 { r.index == index } else { false } }) {
            list.scrollItemToVisible(item.key) // `scrollIntoView({ block: "nearest" })`
        }
    }

    private var searchResultCount: Int {
        list.items.reduce(0) { n, item in if case .searchResult = item { n + 1 } else { n } }
    }

    func selectSearchResult(_ id: ThreadId) {
        clearSearch()
        state.activeThreadId = id
        actions.openThread(id)
    }

    /// `handleThreadSearchKeyDown`: Escape clears, arrows move the highlight with wrap, Enter opens it.
    /// Focus stays in the field.
    func searchCommand(_ selector: Selector) -> Bool {
        guard isSearching else { return false }
        if selector == #selector(NSResponder.cancelOperation(_:)) { clearSearch(); return true }
        let n = searchResultCount
        guard n > 0 else { return false }
        switch selector {
        case #selector(NSResponder.moveDown(_:)): setSearchHighlight((searchHighlight + 1) % n, scroll: true)
        case #selector(NSResponder.moveUp(_:)): setSearchHighlight((searchHighlight - 1 + n) % n, scroll: true)
        case #selector(NSResponder.insertNewline(_:)):
            for case .searchResult(let r) in list.items where r.index == searchHighlight { selectSearchResult(r.id) }
        default: return false
        }
        return true
    }

    // MARK: Selection and rename (Sidebar.tsx:3255-3320, threadSelectionStore.ts)

    /// The Shift-click range anchor (`anchorThreadKey`).
    public private(set) var selectionAnchor: ThreadId?
    public var selectedThreadIds: Set<ThreadId> { state.selectedThreadIds }

    /// `handleThreadClick`: Cmd toggles the row in the selection, Shift selects the range from the anchor,
    /// the second click of a double click renames, a plain click clears the selection and opens the thread.
    func rowClicked(_ id: ThreadId) {
        let event = NSApp.currentEvent
        let mouse = event.map { $0.type == .leftMouseUp || $0.type == .leftMouseDown } ?? false
        let flags = mouse ? event?.modifierFlags ?? [] : []
        if flags.contains(.command) { toggleSelection(id); return }
        if flags.contains(.shift) { selectRange(to: id); return }
        if mouse, (event?.clickCount ?? 1) >= 2 { startRename(id); return }
        clearSelection()
        selectionAnchor = id
        state.activeThreadId = id
        actions.openThread(id)
    }

    func toggleSelection(_ id: ThreadId) {
        var next = state.selectedThreadIds
        if next.remove(id) == nil { next.insert(id); selectionAnchor = id }
        state.selectedThreadIds = next
    }

    /// `rangeSelectTo`: every row between the anchor and `id` in list order; without an anchor in the
    /// list, `id` alone, which becomes the anchor.
    func selectRange(to id: ThreadId) {
        let ordered = list.items.compactMap { if case .row(let r) = $0 { r.id } else { nil } }
        var next = state.selectedThreadIds
        if let anchor = selectionAnchor, let a = ordered.firstIndex(of: anchor), let b = ordered.firstIndex(of: id) {
            next.formUnion(ordered[min(a, b)...max(a, b)])
        } else {
            next.insert(id)
            selectionAnchor = id
        }
        state.selectedThreadIds = next
    }

    /// `navigateToThread` (Sidebar.tsx:3144-3158) for opens that don't come from a row click, such as
    /// `thread.jump.N` and `thread.previous`/`next` (Sidebar.tsx:4881-4889): drops the selection and
    /// moves the Shift-click anchor to the opened thread.
    public func navigated(to id: ThreadId) {
        if !state.selectedThreadIds.isEmpty { state.selectedThreadIds = [] }
        selectionAnchor = id
    }

    /// Escape drops a multi-selection (_chat.tsx:98-102), but an open dialog takes it first: base-ui's dismiss
    /// listener sits on the document, ahead of the chat layout's window listener, and closes the dialog.
    public func escapeClearsSelection(_ event: NSEvent) -> Bool {
        guard event.keyCode == 53, !state.selectedThreadIds.isEmpty, !ModalHost.isPresented(in: event.window) else { return false }
        clearSelection()
        return true
    }

    public func clearSelection() {
        guard !state.selectedThreadIds.isEmpty || selectionAnchor != nil else { return }
        state.selectedThreadIds = []
        selectionAnchor = nil
    }

    /// Deselects threads (deleted ones, `removeFromSelection`).
    public func deselect(_ ids: [ThreadId]) {
        state.selectedThreadIds.subtract(ids)
        if let anchor = selectionAnchor, ids.contains(anchor) { selectionAnchor = nil }
    }

    /// `startThreadRename`: the row's title turns into a field holding the title, selected.
    public func startRename(_ id: ThreadId) {
        guard let thread = snapshot?.threads.first(where: { $0.id == id }) else { return }
        list.renameField.begin(id, title: thread.title)
        state.renamingThreadId = id
        if let frame = list.rowFrame(id) { list.scrollToVisible(frame) }
        list.needsLayout = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.state.renamingThreadId == id else { return }
            self.list.layoutSubtreeIfNeeded()
            self.list.renameField.focus()
        }
    }

    public var renamingThreadId: ThreadId? { state.renamingThreadId }

    func endRename() {
        state.renamingThreadId = nil
    }

    // MARK: Hover card

    /// A checkout's branch arrived or changed: the open card shows or hides its mismatch line.
    public func checkoutBranchChanged() { list.refreshHoverCard() }

    /// `SidebarThreadTooltip`'s props for a thread.
    func hoverCardModel(_ id: ThreadId) -> SidebarThreadHoverCardModel? {
        guard let snapshot, let thread = snapshot.threads.first(where: { $0.id == id }) ?? snapshot.archivedThreads.first(where: { $0.id == id })
        else { return nil }
        var m = SidebarThreadHoverCardModel(title: thread.title)
        let project = snapshot.projects.first { $0.id == thread.projectId }
        let group = SidebarModel.buildProjectGroups(snapshot.projects, preferredEnvironmentId: state.environments.primaryId)
            .first { $0.memberProjectIds.contains(thread.projectId) }
        m.projectLabel = group?.label ?? project?.title
        m.projectIcon = project.map(ProjectIconSource.init)
        if let env = id.environmentId {
            m.environmentLabel = state.environments.labels[env]
            m.environmentMachine = state.environments.machine(env)
        }
        m.branch = thread.branch
        // Sidebar.tsx:1243-1255, 1350-1355: the checkout's status when the thread has a branch; only a
        // Current checkout thread (no worktree) can be on another branch.
        if thread.branch != nil, thread.worktreePath == nil, let env = id.environmentId, let root = project?.workspaceRoot {
            m.branchMismatch = BranchToolbarLogic.localCheckoutBranchMismatch(
                envMode: .local, worktreePath: nil, threadBranch: thread.branch, currentBranch: actions.checkoutBranch(env, root)) != nil
        }
        if let provider = actions.hoverProvider(thread) {
            m.provider = (provider.driver, provider.label)
            m.providerAccent = provider.accent
            m.handedOffFrom = provider.handedOffFrom
        }
        m.terminalProcessCount = state.terminalProcesses[id] ?? 0
        if let runtime = SidebarModel.shellRuntime(thread), runtime.lastError != nil {
            m.errorIsUsageLimit = runtime.lastErrorClass == .usageLimit
        }
        if !(thread.pullRequests ?? []).isEmpty { m.pullRequests = SidebarPullRequestBadge(thread) }
        return m
    }

    // MARK: Drafts

    /// The composer's drafts with a prompt, and the open one. The open draft's row keeps the content it had
    /// when it opened and never repaints while the user types; a draft opened empty shows no row until
    /// it is left (`SidebarDraftBlock`, Sidebar.tsx:962-1034).
    public func setDrafts(_ drafts: [SidebarDraft], activeDraftId: String?) {
        let activeDraftId = isOnUtilityPage ? nil : activeDraftId
        if activeDraftId != frozenDraft.id {
            frozenDraft = (activeDraftId, drafts.first { $0.id == activeDraftId && !SidebarListBuilder.draftPreview($0.prompt).isEmpty })
        }
        var shown = drafts.filter { $0.id != activeDraftId }
        // Gated on the live draft, so a send or discard removes the row at once.
        if let frozen = frozenDraft.draft, drafts.contains(where: { $0.id == frozen.id }) { shown.append(frozen) }
        var next = state
        next.drafts = shown
        next.activeDraftId = activeDraftId
        state = next
    }

    // MARK: Project scope

    public func setProjectScope(_ key: String?) {
        // Scope flips drop the selection: rows selected under the old scope may be hidden now (Sidebar.tsx:2710-2714).
        clearSelection()
        state.projectScopeKey = key
        if let key { scopeDefaults?.set(key, forKey: Self.scopeDefaultsKey) } else { scopeDefaults?.removeObject(forKey: Self.scopeDefaultsKey) }
    }

    private var scopedGroup: SidebarModel.ProjectGroup? {
        guard let key = state.projectScopeKey, let snapshot else { return nil }
        return SidebarModel.buildProjectGroups(snapshot.projects, preferredEnvironmentId: state.environments.primaryId).first { $0.key == key }
    }

    func updateScopeTrigger() {
        let group = scopedGroup
        filterMonogram.isHidden = group == nil
        if let group { filterMonogram.projectTitle = group.representative.title; filterMonogram.source = ProjectIconSource(group.representative) }
        if (filterButton.icon == nil) != (group != nil) { filterButton.icon = group == nil ? .listFilter : nil }
        let label = group.map { "Filter threads by project: \($0.label)" } ?? "Filter threads by project"
        filterButton.setAccessibilityLabel(label)
        filterButton.toolTip = label
        let hasProjects = !(snapshot?.projects.isEmpty ?? true)
        if filterButton.isHidden == hasProjects { needsLayout = true }
    }

    /// Opens the scope combobox under the search field, or closes it when it is open.
    func toggleScopePopup() {
        let trigger: NSView = filterButton, field: NSView = search
        guard let host = trigger.popupHost else { return }
        if let open = scopePopup, host.popups.contains(where: { $0 === open }) { host.close(open); return }
        let view = SidebarProjectScopeView(
            groups: SidebarListBuilder.projectScopeGroups(snapshot: snapshot, primaryEnvironmentId: state.environments.primaryId,
                                                          order: SidebarModel.SortOrder(rawValue: ClientSettingsStore.shared.current.string("sidebarProjectSortOrder")) ?? .updatedAt),
            selectedKey: state.projectScopeKey, minimumWidth: field.frame.width, environments: state.environments)
        view.onSelect = { [weak self] key in
            self?.setProjectScope(key)
            self?.closeScopePopup()
        }
        view.onSettings = { [weak self] key in
            self?.closeScopePopup()
            self?.actions.openProjectSettings(key)
        }
        let anchor = trigger.convert(field.bounds, from: field)
        let popup = host.open(PickerPopupView(view), trigger: trigger, anchorRect: anchor, placement: .dropdown,
                              swallowsOutsideClick: true)
        popup.onClose = { [weak self] in self?.scopePopup = nil }
        scopePopup = popup
        window?.makeFirstResponder(view.search)
    }

    private func closeScopePopup() {
        if let scopePopup { filterButton.popupHost?.close(scopePopup) }
        scopePopup = nil
    }

    /// The open scope popup's body, for tests.
    var scopePopupView: SidebarProjectScopeView? { (scopePopup?.content as? PickerPopupView)?.body as? SidebarProjectScopeView }

    // MARK: Label refresh

    /// One tick on the shared `LabelClock`, aimed at the next moment a visible label changes. The clock
    /// holds it while the window is hidden or occluded and delivers it as soon as the window shows
    /// again, so labels are fresh after a hidden stretch. None when no visible label can change.
    func scheduleLabelTimer() {
        guard window != nil else { LabelClock.shared.cancel(self); return }
        let ms = nowMs, rows = list.visibleRowModels
        // The earliest wake too, 50 ms late, so the Snoozed shelf empties the moment a snooze ends even while its rows
        // are collapsed or scrolled away (Sidebar.tsx:3008-3022).
        // A lazy filter/map chain repeatedly copies the large ThreadShell value while advancing its
        // iterator. Read only the two fields this scan needs, without intermediate thread values.
        var earliestWake: Int64?
        if let threads = snapshot?.threads {
            for i in threads.indices {
                guard threads[i].archivedAt == nil, let wake = threads[i].snoozedUntil?.epochMs,
                      wake > ms else { continue }
                earliestWake = min(earliestWake ?? wake, wake)
            }
        }
        let wakeAt = earliestWake.map { $0 + 50 }
        let rebuildAt = [SidebarListBuilder.nextLabelChange(rows, nowMs: ms, working: false), wakeAt].compactMap { $0 }.min()
        let workingAt = SidebarListBuilder.nextLabelChange(rows, nowMs: ms, relative: false)
        guard let next = [rebuildAt, workingAt].compactMap({ $0 }).min() else { LabelClock.shared.cancel(self); return }
        LabelClock.shared.schedule(self, in: Double(next - ms) / 1000) { [weak self] in self?.labelTimerFired(rebuildAt: rebuildAt) }
    }

    /// Exposed so tests can see whether a tick is pending and when.
    public var pendingLabelRefresh: Date? { LabelClock.shared.due(for: self) }

    /// A relative time or snooze label can move rows between sections, so its change rebuilds the list
    /// (without motion after a hidden stretch). A Working duration only redraws its own row, as T3's
    /// self-ticking `WorkingDuration` does (Sidebar.tsx:361-372).
    private func labelTimerFired(rebuildAt: Int64?) {
        let ms = nowMs
        if let rebuildAt, rebuildAt <= ms {
            rebuild(animated: ms - rebuildAt < 2_000)
        } else {
            list.nowMs = ms
            scheduleLabelTimer()
        }
        list.tickWorkingRows()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleLabelTimer()
    }

    /// A sidebar shown again after a collapse catches up a tick it skipped while hidden.
    public override func viewDidUnhide() {
        super.viewDidUnhide()
        LabelClock.shared.visibilityChanged()
    }

    // MARK: Layout

    public override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        // Titlebar row, 52px. The art bleeds 80px under the search row.
        backdrop.frame = NSRect(x: 0, y: 0, width: w, height: 80)
        let controlsLeft = SidebarMetrics.controlsLeft(windowedMac: windowedMac)
        trigger.frame = NSRect(x: controlsLeft + 1, y: (52 - 28) / 2, width: 28, height: 28)
        let bs = brand.intrinsicContentSize
        brand.frame = NSRect(x: SidebarMetrics.titlebarContentLeft(windowedMac: windowedMac), y: 12, width: min(bs.width, max(0, w - 12 - 130)), height: 28)
        let pillSize = environmentPill.intrinsicContentSize
        environmentPill.frame = NSRect(x: brand.frame.maxX + 12, y: 18, width: pillSize.width, height: pillSize.height)
        environmentPill.alphaValue = environmentPill.frame.maxX <= w - 12 ? 1 : 0
        // Fixed header group, `p-2`: search, then the 28px icon buttons.
        let rowY: CGFloat = 52 + 8
        var right = w - 8
        // Without projects there is nothing to scope, so scope and add project stay out (SidebarThreadHeader.tsx:127-135).
        let hasProjects = !(snapshot?.projects.isEmpty ?? true)
        for b in [newThreadButton, addProjectButton, filterButton] {
            b.isHidden = b !== newThreadButton && !hasProjects
            if b.isHidden { continue }
            b.frame = NSRect(x: right - 28, y: rowY + 2, width: 28, height: 28)
            right -= 28
        }
        filterMonogram.frame = NSRect(x: 6, y: 6, width: 16, height: 16)
        search.frame = NSRect(x: 8, y: rowY, width: max(0, right - 4 - 8), height: 32)
        // Footer: `flex-col gap-2 px-2 py-1`: the undo notice, then 32px icon buttons 4px apart.
        let menuTop = h - 36
        var footerTop = h - 40
        var stackTop = menuTop
        if !providerUpdatePill.isHidden {
            providerUpdatePill.frame = NSRect(x: 8, y: stackTop - 8 - 28, width: w - 16, height: 28)
            stackTop = providerUpdatePill.frame.minY
            footerTop = stackTop - 4
        }
        if !undoNotice.isHidden {
            let nh = undoNotice.height(forWidth: w - 16)
            undoNotice.frame = NSRect(x: 8, y: stackTop - 8 - nh, width: w - 16, height: nh)
            footerTop = undoNotice.frame.minY - 4
        }
        var fx: CGFloat = 8
        for b in [settingsButton, pullRequestsButton, usageButton] {
            b.isHidden = isOnUtilityPage || b === pullRequestsButton && !showsPullRequests
            if b.isHidden { continue }
            b.frame = NSRect(x: fx, y: menuTop, width: 32, height: 32)
            fx += 36
        }
        backButton.isHidden = !isOnUtilityPage
        // `SidebarMenu` is a `gap-1` row; Back is `flex-1`, the update pill `ml-auto shrink-0`.
        let pillRoom: CGFloat = updatePill.isHidden ? 0 : 32 + 4
        backButton.frame = NSRect(x: 8, y: menuTop, width: max(0, w - 16 - pillRoom), height: 32)
        updatePill.frame = NSRect(x: w - 8 - 32, y: menuTop, width: 32, height: 32)
        scrollArea.frame = NSRect(x: 0, y: 100, width: w, height: max(0, footerTop - 100))
        list.frame.size.width = w
        list.needsLayout = true
    }
}
