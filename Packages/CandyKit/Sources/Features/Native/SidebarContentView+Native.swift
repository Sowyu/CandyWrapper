import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// Glass Native's sidebar (docs/glass-native.md phase 2): the same content view, state and actions, with the native
/// list, search field, filter menu and picker in place of T3's custom-drawn ones. The native views exist only while
/// the native presentation shows the sidebar.
extension SidebarContentView {
    private var classicChrome: [NSView] {
        [scrollArea, search, filterButton, addProjectButton, newThreadButton, settingsButton, pullRequestsButton, usageButton, backButton]
    }

    func applyPresentation() {
        if hidesCustomChrome, nativeList == nil {
            let native = NativeSidebarListView(frame: bounds)
            let chrome = NativeSidebarChrome(frame: .zero)
            nativeList = native
            nativeChrome = chrome
            addSubview(native)
            addSubview(chrome)
            list.setItems([], animated: false)
            for view in classicChrome { view.isHidden = true }
            chrome.search.stringValue = searchQuery
            wireNative()
        } else if !hidesCustomChrome, let native = nativeList {
            native.closeHoverCard()
            native.removeFromSuperview()
            nativeChrome?.removeFromSuperview()
            nativeList = nil
            nativeChrome = nil
            scrollArea.isHidden = false
            search.isHidden = false
            search.text = searchQuery
        } else {
            return
        }
        needsLayout = true
        rebuild(animated: false)
        updateScopeTrigger()
    }

    func wireNative() {
        guard let native = nativeList, let chrome = nativeChrome else { return }
        native.actions = actions
        native.onOpen = { [weak self] in self?.rowClicked($0) }
        native.onToggleShelf = { [weak self] in self?.toggleShelf($0) }
        native.onShowMore = { [weak self] in self?.state.settledVisibleCount += SidebarListBuilder.settledPageCount }
        native.onOpenDraft = { [weak self] in self?.actions.openDraft($0) }
        native.onOpenSearchResult = { [weak self] in self?.selectSearchResult($0) }
        native.onVisibleRowsChange = { [weak self] in self?.scheduleLabelTimer() }
        native.onKeyboardSelection = { [weak self] ids in self?.state.selectedThreadIds = Set(ids) }
        native.onRenameCommit = { [weak self] id, title, original in
            self?.endRename()
            self?.actions.rename(id, title, original)
        }
        native.onRenameCancel = { [weak self] in self?.endRename() }
        native.hoverCard = { [weak self] in self?.hoverCardModel($0) }
        native.environmentLabel = { [weak self] in self?.state.environments.labels[$0] }
        native.environmentMachine = { [weak self] in self?.state.environments.machine($0) ?? "server" }
        native.settlementSupported = { [weak self] in self?.state.capabilities.threadSettlement ?? true }
        native.snoozeSupported = { [weak self] in self?.state.capabilities.threadSnooze ?? true }
        // The app sets the sort rules on the classic list; the native one reads them from there.
        native.canSortThread = { [weak self] in self?.list.canSortThread?($0) ?? false }
        native.canSortDrop = { [weak self] in self?.list.canSortDrop?($0, $1, $2) ?? false }
        native.onSortDrop = { [weak self] in self?.list.onSortDrop?($0, $1, $2) }
        chrome.onChange = { [weak self] text in
            guard let self, text != self.searchQuery else { return }
            self.setSearchQuery(text)
        }
        chrome.onCommand = { [weak self] in self?.searchCommand($0) ?? false }
        chrome.filter.target = self
        chrome.filter.action = #selector(showFilterMenu(_:))
        chrome.segments.target = self
        chrome.segments.action = #selector(segmentChanged(_:))
        syncSegments()
    }

    /// Threads while the thread view shows, Pull requests on that page, neither on Usage.
    func syncSegments() {
        guard let segments = nativeChrome?.segments else { return }
        segments.isHidden = !showsPullRequests
        segments.selectedSegment = !isOnUtilityPage ? 0 : showsPullRequestsPage ? 1 : -1
    }

    @objc private func segmentChanged(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 1 {
            actions.openPullRequests()
        } else if isOnUtilityPage {
            actions.back()
        }
        syncSegments()
    }

    /// Cmd+F while the native list or a row has focus: the search field takes it (T3 Mobile's Cmd+F).
    public func focusSearch(_ event: NSEvent) -> Bool {
        guard let chrome = nativeChrome, let native = nativeList, event.charactersIgnoringModifiers?.lowercased() == "f",
              event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
              let responder = window?.firstResponder as? NSView, responder.isDescendant(of: native) else { return false }
        window?.makeFirstResponder(chrome.search)
        return true
    }

    // MARK: Filter menu (home/home-list-filter-menu.ts): Environment and Project, then Add project

    @objc private func showFilterMenu(_ sender: NSButton) {
        var items: [ThreadMenuItem] = []
        let environments = state.environments.labels.sorted { $0.value.localizedCompare($1.value) == .orderedAscending }
        if environments.count > 1 {
            items.append(ThreadMenuItem("environment", "Environment", children:
                [ThreadMenuItem("env:", "All environments", checked: environmentFilter == nil)]
                + environments.map { ThreadMenuItem("env:\($0.key)", $0.value, checked: environmentFilter == $0.key) }))
        }
        let order = SidebarModel.SortOrder(rawValue: ClientSettingsStore.shared.current.string("sidebarProjectSortOrder")) ?? .updatedAt
        let groups = SidebarListBuilder.projectScopeGroups(snapshot: snapshot, primaryEnvironmentId: state.environments.primaryId, order: order)
        if !groups.isEmpty {
            items.append(ThreadMenuItem("project", "Project", children:
                [ThreadMenuItem("project:", "All projects", checked: state.projectScopeKey == nil)]
                + groups.map { ThreadMenuItem("project:\($0.key)", $0.label, checked: state.projectScopeKey == $0.key) }))
        }
        items.append(ThreadMenuItem("add-project", "Add project…", separatorBefore: !items.isEmpty))
        items.append(ThreadMenuItem("usage", "Usage"))
        let menu = NativeItemContextMenu.make(items) { [weak self] choice in self?.chooseFilter(choice) }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    func chooseFilter(_ choice: String) {
        if choice.hasPrefix("env:") {
            let env = String(choice.dropFirst(4))
            setEnvironmentFilter(env.isEmpty ? nil : env)
        } else if choice.hasPrefix("project:") {
            let key = String(choice.dropFirst(8))
            setProjectScope(key.isEmpty ? nil : key)
        } else if choice == "add-project" {
            actions.addProject()
        } else if choice == "usage" {
            actions.openUsage()
        }
    }

    /// Shows only the projects of one environment, through the list state's project scope ids.
    public func setEnvironmentFilter(_ env: String?) {
        clearSelection()
        environmentFilter = env
        syncEnvironmentFilter()
        updateScopeTrigger()
    }

    /// A snapshot can bring projects in or take them away: the filter's ids follow.
    func syncEnvironmentFilter() {
        let ids = environmentFilter.map { env in Set((snapshot?.projects ?? []).filter { $0.id.environmentId == env }.map(\.id)) }
        if state.scopedProjectIds != ids { state.scopedProjectIds = ids }
    }

    func layoutNative() {
        guard let native = nativeList, let chrome = nativeChrome else { return }
        let w = bounds.width, h = bounds.height
        // The column lines the hidden 52pt titlebar row up with the toolbar, so the native top starts below it.
        let top: CGFloat = 52 + 6
        chrome.frame = NSRect(x: 0, y: top, width: w, height: showsPullRequests ? NativeSidebarChrome.height : 32)
        var bottom = h
        if !providerUpdatePill.isHidden {
            providerUpdatePill.frame = NSRect(x: 8, y: bottom - 8 - 28, width: w - 16, height: 28)
            bottom = providerUpdatePill.frame.minY
        }
        if !undoNotice.isHidden {
            let nh = undoNotice.height(forWidth: w - 16)
            undoNotice.frame = NSRect(x: 8, y: bottom - 8 - nh, width: w - 16, height: nh)
            bottom = undoNotice.frame.minY
        }
        updatePill.frame = NSRect(x: w - 8 - 32, y: bottom - 8 - 32, width: 32, height: 32)
        if !updatePill.isHidden { bottom = updatePill.frame.minY }
        native.frame = NSRect(x: 0, y: chrome.frame.maxY + 4, width: w, height: max(0, bottom - chrome.frame.maxY - 4))
    }
}
