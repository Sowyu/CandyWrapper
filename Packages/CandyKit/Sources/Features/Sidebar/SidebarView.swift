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
    /// Right click on a thread row: the row view and the event, for the native menu.
    public var contextMenu: (ThreadId, NSEvent, NSView) -> Void = { _, _, _ in }
    /// The undo notice's button (`undoLatestThreadAction`).
    public var undo: () -> Void = {}
    /// The footer's Back on a utility page (SidebarChrome.tsx:203-210).
    public var back: () -> Void = {}
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
    let brand = SidebarBrandView()
    let search = SidebarSearchFieldView()
    let filterButton = SidebarContentView.headerButton(.folder, "Filter threads by project")
    let addProjectButton = SidebarContentView.headerButton(.folderPlus, "Add project")
    let newThreadButton = SidebarContentView.headerButton(.squarePen, "New thread")
    let settingsButton = SidebarContentView.footerButton(.settings, "Settings")
    let pullRequestsButton = SidebarContentView.footerButton(.gitPullRequestArrow, "Pull Requests")
    let usageButton = SidebarContentView.footerButton(.chartNoAxesColumn, "Usage")
    let backButton = SidebarMenuButtonView("Back", icon: .arrowLeft)
    let undoNotice = SidebarUndoNoticeView()

    public var actions = SidebarActions() { didSet { wireActions() } }
    public private(set) var snapshot: ShellSnapshot?
    public var state = SidebarListState() { didSet { if state != oldValue { rebuild(animated: true) } } }
    /// Traffic lights: the brand and toggle sit after `--workspace-controls-left` (90px) on windowed macOS.
    public var windowedMac = true { didSet { needsLayout = true } }
    public var stage: SidebarStage = .nightly { didSet { applyStage() } }
    public var showsPullRequests = true { didSet { needsLayout = true } }
    /// On Pull Requests or Usage the footer shows only Back (`isSidebarUtilityPage`).
    public var isOnUtilityPage = false { didSet { needsLayout = true } }
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

    private var labelTimer: Timer?
    private var occlusionObserver: NSObjectProtocol?

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
        addSubview(scrollArea)
        addSubview(brand)
        addSubview(trigger)
        undoNotice.isHidden = true
        undoNotice.shortcut = undoShortcut
        backButton.isHidden = true
        for v in [search, filterButton, addProjectButton, newThreadButton, settingsButton, pullRequestsButton, usageButton,
                  backButton, undoNotice] as [NSView] {
            addSubview(v)
        }
        list.onVisibleRowsChange = { [weak self] in self?.scheduleLabelTimer() }
        list.onToggleShelf = { [weak self] shelf in
            guard let self else { return }
            switch shelf {
            case .settled: self.state.settledExpanded.toggle(); self.state.settledVisibleCount = SidebarListBuilder.settledInitialCount
            case .snoozed: self.state.snoozedExpanded.toggle()
            }
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
    }

    static func headerButton(_ icon: IconName, _ label: String) -> SidebarMenuButtonView {
        let b = SidebarMenuButtonView("", icon: icon, size: .icon)
        b.setAccessibilityLabel(label)
        b.toolTip = label
        return b
    }

    static func footerButton(_ icon: IconName, _ label: String) -> SidebarMenuButtonView { headerButton(icon, label) }

    private func applyStage() {
        backdrop.isHidden = stage != .nightly
        brand.onBackdrop = stage == .nightly
        trigger.mediaTint = stage == .nightly ? StageBackdropView.ink() : nil
    }

    private func wireActions() {
        list.onOpen = { [weak self] id in
            guard let self else { return }
            self.state.activeThreadId = id
            self.actions.openThread(id)
        }
        // Rows keep these closures across reuse, so they read `actions` when they fire.
        list.rowActions = SidebarRowActions(
            settle: { [weak self] in self?.actions.settle($0) }, unsettle: { [weak self] in self?.actions.unsettle($0) },
            snooze: { [weak self] in self?.actions.snooze($0, $1) }, unsnooze: { [weak self] in self?.actions.unsnooze($0) },
            unpin: { [weak self] in self?.actions.unpin($0) }, contextMenu: { [weak self] in self?.actions.contextMenu($0, $1, $2) })
        undoNotice.onUndo = { [weak self] in self?.actions.undo() }
        backButton.action = { [weak self] in self?.actions.back() }
        list.onOpenDraft = { [weak self] id in self?.actions.openDraft(id) }
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
    public func setSnapshot(_ snapshot: ShellSnapshot?, animated: Bool = true) {
        self.snapshot = snapshot
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

    private var nowMs: Int64 { TimestampFormat.nowMs(now()) }

    /// The thread rows in display order, outside search (`orderedThreadKeys`, Sidebar.tsx:3073-3079):
    /// what `thread.previous`, `thread.next` and `thread.jump.N` walk.
    public var orderedThreadIds: [ThreadId] {
        SidebarListBuilder.items(snapshot: snapshot, state: state, nowMs: nowMs).compactMap {
            if case .row(let row) = $0 { row.id } else { nil }
        }
    }

    private func rebuild(animated: Bool) {
        let ms = nowMs
        list.nowMs = ms
        if isSearching {
            var items = searchItems(nowMs: ms)
            // A new result order puts the highlight back on the first result (Sidebar.tsx:2924-2930).
            let order = items.map(\.key).joined(separator: "\0")
            if order != searchOrderKey {
                searchOrderKey = order
                if searchHighlight != 0 { searchHighlight = 0; items = searchItems(nowMs: ms) }
            }
            list.setItems(items, animated: false)
        } else {
            searchOrderKey = ""
            list.setItems(SidebarListBuilder.items(snapshot: snapshot, state: state, nowMs: ms), animated: animated)
        }
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

    // MARK: Drafts

    /// The composer's drafts with a prompt, and the open one. The open draft's row keeps the content it had
    /// when it opened and never repaints while the user types; a draft opened empty shows no row until
    /// it is left (`SidebarDraftBlock`, Sidebar.tsx:962-1034).
    public func setDrafts(_ drafts: [SidebarDraft], activeDraftId: String?) {
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
        state.projectScopeKey = key
        if let key { scopeDefaults?.set(key, forKey: Self.scopeDefaultsKey) } else { scopeDefaults?.removeObject(forKey: Self.scopeDefaultsKey) }
    }

    private var scopedGroup: SidebarModel.ProjectGroup? {
        guard let key = state.projectScopeKey, let snapshot else { return nil }
        return SidebarModel.buildProjectGroups(snapshot.projects, preferredEnvironmentId: state.environments.primaryId).first { $0.key == key }
    }

    private func updateScopeTrigger() {
        let group = scopedGroup
        filterMonogram.isHidden = group == nil
        if let group { filterMonogram.projectTitle = group.representative.title; filterMonogram.source = ProjectIconSource(group.representative) }
        if (filterButton.icon == nil) != (group != nil) { filterButton.icon = group == nil ? .folder : nil }
        let label = group.map { "Filter threads by project: \($0.label)" } ?? "Filter threads by project"
        filterButton.setAccessibilityLabel(label)
        filterButton.toolTip = label
        let hasProjects = !(snapshot?.projects.isEmpty ?? true)
        if filterButton.isHidden == hasProjects { needsLayout = true }
    }

    /// Opens the scope combobox under the search field, or closes it when it is open.
    func toggleScopePopup() {
        guard let host = filterButton.popupHost else { return }
        if let open = scopePopup, host.popups.contains(where: { $0 === open }) { host.close(open); return }
        let view = SidebarProjectScopeView(
            groups: SidebarListBuilder.projectScopeGroups(snapshot: snapshot, primaryEnvironmentId: state.environments.primaryId),
            selectedKey: state.projectScopeKey, minimumWidth: search.frame.width, environments: state.environments)
        view.onSelect = { [weak self] key in
            self?.setProjectScope(key)
            self?.closeScopePopup()
        }
        view.onSettings = { [weak self] key in
            self?.closeScopePopup()
            self?.actions.openProjectSettings(key)
        }
        let anchor = filterButton.convert(search.bounds, from: search)
        let popup = host.open(PickerPopupView(view), trigger: filterButton, anchorRect: anchor, placement: .dropdown,
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

    /// One timer, aimed at the next moment a visible label changes, with 10% tolerance. None while the
    /// window is hidden or occluded, or when no visible label can change.
    func scheduleLabelTimer() {
        labelTimer?.invalidate()
        labelTimer = nil
        guard let window, window.occlusionState.contains(.visible) || window.isVisible && window.occlusionState.isEmpty else { return }
        let ms = nowMs
        guard let next = SidebarListBuilder.nextLabelChange(list.visibleRowModels, nowMs: ms) else { return }
        let interval = max(0.05, Double(next - ms) / 1000)
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.labelTimerFired() }
        }
        timer.tolerance = interval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        labelTimer = timer
    }

    /// Exposed so tests can see whether a timer is pending and when.
    public var pendingLabelRefresh: Date? { labelTimer?.fireDate }

    private func labelTimerFired() {
        labelTimer = nil
        rebuild(animated: true)
        list.tickWorkingRows()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        guard let window else { labelTimer?.invalidate(); labelTimer = nil; return }
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Labels may be stale after a hidden stretch: rebuild once, then aim the timer again.
                if self.window?.occlusionState.contains(.visible) == true { self.rebuild(animated: false) } else {
                    self.labelTimer?.invalidate(); self.labelTimer = nil
                }
            }
        }
        scheduleLabelTimer()
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
        if !undoNotice.isHidden {
            let nh = undoNotice.height(forWidth: w - 16)
            undoNotice.frame = NSRect(x: 8, y: menuTop - 8 - nh, width: w - 16, height: nh)
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
        backButton.frame = NSRect(x: 8, y: menuTop, width: w - 16, height: 32)
        scrollArea.frame = NSRect(x: 0, y: 100, width: w, height: max(0, footerTop - 100))
        list.frame.size.width = w
        list.needsLayout = true
    }
}
