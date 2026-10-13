import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// Glass Native's sidebar (docs/glass-native.md phase 2): T3 Code desktop's sidebar with the same content view,
/// state and actions, where native controls take the custom-drawn ones' places: the table, the search field, the
/// project menu and glass footer buttons. The native views exist only while the native presentation shows the sidebar.
extension SidebarContentView {
    /// Classic's search row and footer buttons, in their stacking order: below the undo notice, above the brand.
    private var classicButtons: [NSView] {
        [search, filterButton, addProjectButton, newThreadButton, settingsButton, pullRequestsButton, usageButton, backButton]
    }

    func applyPresentation() {
        if hidesCustomChrome, nativeList == nil {
            let native = NativeSidebarListView(frame: bounds)
            let chrome = NativeSidebarChrome(frame: .zero)
            let footer = NativeSidebarFooter(frame: .zero)
            nativeList = native
            nativeChrome = chrome
            nativeFooter = footer
            addSubview(native)
            addSubview(chrome)
            addSubview(footer)
            footer.backTarget = self
            footer.backAction = #selector(footerPressed(_:))
            footer.showsBack = isOnUtilityPage
            footer.showsPullRequests = showsPullRequests
            list.setItems([], animated: false)
            // Out of the window, so the split view's layout engine and the layer tree skip classic's chrome.
            for view in [scrollArea, trigger] + classicButtons {
                view.isHidden = true
                view.removeFromSuperview()
            }
            chrome.search.stringValue = searchQuery
            wireNative()
        } else if !hidesCustomChrome, let native = nativeList {
            native.closeHoverCard()
            native.removeFromSuperview()
            nativeChrome?.removeFromSuperview()
            nativeFooter?.removeFromSuperview()
            nativeList = nil
            nativeChrome = nil
            nativeFooter = nil
            addSubview(scrollArea, positioned: .below, relativeTo: brand)
            addSubview(trigger, positioned: .above, relativeTo: brand)
            for view in classicButtons { addSubview(view, positioned: .below, relativeTo: undoNotice) }
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
        guard let native = nativeList, let chrome = nativeChrome, let footer = nativeFooter else { return }
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
        chrome.addProject.target = self
        chrome.addProject.action = #selector(addProjectPressed)
        chrome.newThread.target = self
        chrome.newThread.action = #selector(newThreadPressed)
        for b in [footer.settings, footer.pullRequests, footer.usage] {
            b.target = self
            b.action = #selector(footerPressed(_:))
        }
    }

    @objc private func addProjectPressed() { actions.addProject() }
    @objc private func newThreadPressed() { actions.newThread() }

    @objc private func footerPressed(_ sender: NSButton) {
        guard let footer = nativeFooter else { return }
        switch sender {
        case footer.settings: actions.openSettings()
        case footer.pullRequests: actions.openPullRequests()
        case footer.usage: actions.openUsage()
        default: actions.back()
        }
    }

    /// Cmd+F while the native list or a row has focus: the search field takes it.
    public func focusSearch(_ event: NSEvent) -> Bool {
        guard let chrome = nativeChrome, let native = nativeList, event.charactersIgnoringModifiers?.lowercased() == "f",
              event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
              let responder = window?.firstResponder as? NSView, responder.isDescendant(of: native) else { return false }
        window?.makeFirstResponder(chrome.search)
        return true
    }

    // MARK: Project filter

    /// Classic's project combobox (Sidebar.tsx:4990-5122): search, environment badges and per-project settings,
    /// under the native search field.
    @objc private func showFilterMenu(_ sender: NSButton) { toggleScopePopup() }

    func layoutNative() {
        guard let native = nativeList, let chrome = nativeChrome, let footer = nativeFooter else { return }
        let w = bounds.width, h = bounds.height
        // The classic layout below the 52pt titlebar row the toolbar covers: the search row at 60, the list from 100,
        // the footer's 32pt buttons 4pt from the bottom with the notices stacked above them.
        chrome.frame = NSRect(x: 0, y: 60, width: w, height: 32)
        let menuTop = h - 36
        footer.trailingRoom = updatePill.isHidden ? 0 : 36
        footer.frame = NSRect(x: 0, y: menuTop, width: w, height: 32)
        updatePill.frame = NSRect(x: w - 8 - 32, y: menuTop, width: 32, height: 32)
        var footerTop = h - 40, stackTop = menuTop
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
        native.frame = NSRect(x: 0, y: 100, width: w, height: max(0, footerTop - 100))
    }
}
