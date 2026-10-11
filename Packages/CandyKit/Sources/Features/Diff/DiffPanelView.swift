import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// T3's read-only diff panel for one run (DiffPanel.tsx, DiffPanelShell.tsx): a header row with the
/// scope menu, line totals and view toggles, then the virtualized file list. The panel asks for a
/// run's patch through `loader` (`orchestration.getTurnDiff`, or `getFullThreadDiff` for the first
/// run, research note G 5.3), parses it off the main thread and shows every file collapsed.
///
/// The timeline's changed files card opens it with `open(runId:filePath:)`.
public final class DiffPanelView: DSView {
    /// Sends the request and returns the server's reply.
    public typealias Loader = @Sendable (TurnDiffs.Request) async throws -> ThreadTurnDiff

    /// The thread whose runs the panel shows. Changing it clears the panel until `setSummaries`.
    public var threadId: ThreadId? {
        didSet {
            guard threadId != oldValue else { return }
            loadTask?.cancel()
            summaries = []
            selectedRunId = nil
            requestedRunId = nil
            list.setDiff(UnifiedDiff(""))
            fileTree.model = FileTreeModel(); fileTree.changes = [:]
            searchMatches = []; searchIndex = 0
            list.annotations = []; reviewDraft = nil; reviewStart = nil; reviewDraftAnchor = nil; editingReviewId = nil
            hasDiff = false
        }
    }
    public var loader: Loader?
    /// T3's `diffLayout` setting: stacked (unified, the default) or split.
    public var layoutStyle: DiffViewStyle = .unified { didSet { list.style = layoutStyle; layoutToggle.selectedIndex = layoutStyle == .unified ? 0 : 1 } }
    /// `diffWordWrap`, default on.
    public var wrapLines = true { didSet { list.wrap = wrapLines; wrapToggle.isPressed = wrapLines } }
    /// `diffIgnoreWhitespace`, default on; changing it asks the server again.
    public var ignoreWhitespace = true { didSet { whitespaceToggle.isPressed = ignoreWhitespace; if ignoreWhitespace != oldValue { reload() } } }
    /// The right panel's tab mode (`data-preview-panel-mode="inline"`): a 28px header row with 12px
    /// below and no border, as in references 09 and 10. Otherwise the 40px bordered row.
    public var inlineHeader = true { didSet { needsLayout = true; needsDisplay = true } }
    /// T3 shows refresh only for git sources; turn diffs never change.
    public var showsRefresh = false { didSet { refreshButton.isHidden = !showsRefresh; needsLayout = true } }
    public var onOpenFile: (@MainActor (String) -> Void)? { didSet { list.onOpenFile = onOpenFile } }

    public var onReviewComment: ((JSONValue) -> Void)?
    public var onDeleteReviewComment: ((String) -> Void)?
    public var reviewComments: [JSONValue] = [] { didSet { if reviewComments != oldValue { rebuildReviewAnnotations() } } }
    private var reviewStart: (path: String, line: Int)?
    private var reviewDraft: DiffReviewAnnotationView?
    private var reviewDraftAnchor: DiffAnnotation?
    private var editingReviewId: String?

    @discardableResult public func handleReviewEscape() -> Bool {
        guard reviewDraft != nil else { return false }
        reviewDraft = nil; reviewStart = nil; reviewDraftAnchor = nil; editingReviewId = nil
        rebuildReviewAnnotations()
        window?.makeFirstResponder(list)
        return true
    }
    private func rebuildReviewAnnotations() {
        // Drop cached cards when a record changes, including when editing switches view type.
        list.annotations = []
        let section = selectedRunId?.rawValue ?? "diff"
        let records = reviewComments.filter { $0["sectionId"]?.stringValue == section && $0["contextId"]?.stringValue != editingReviewId }
        var byId: [String: JSONValue] = [:]
        var annotations: [DiffAnnotation] = []
        for record in records {
            guard let anchor = DiffReviewContext.anchor(record, diff: list.diff) else { continue }
            annotations.append(anchor); byId[anchor.id] = record
        }
        if let reviewDraftAnchor { annotations.append(reviewDraftAnchor) }
        list.annotationView = { [weak self] annotation in
            guard let self else { return nil }
            if annotation.id == self.reviewDraftAnchor?.id { return self.reviewDraft }
            guard let record = byId[annotation.id] else { return nil }
            let card = DiffReviewCommentCardView(text: record["text"]?.stringValue ?? "")
            card.onDelete = { [weak self] in self?.onDeleteReviewComment?(annotation.id) }
            card.onEdit = { [weak self] in self?.editReview(record, anchor: annotation) }
            return card
        }
        list.annotations = annotations
    }
    private func editReview(_ record: JSONValue, anchor: DiffAnnotation) {
        editingReviewId = anchor.id
        let draft = DiffReviewAnnotationView(); reviewDraft = draft
        draft.editor.text = record["text"]?.stringValue ?? ""
        draft.submit.title = "Save"; draft.submit.isEnabled = true
        reviewDraftAnchor = DiffAnnotation(path: anchor.path, right: anchor.right, line: anchor.line, id: "editing:" + anchor.id)
        draft.onCancel = { [weak self] in self?.handleReviewEscape() }
        draft.onSubmit = { [weak self] text in
            guard let self, case .object(var values) = record else { return }
            values["text"] = .string(String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(16000)))
            self.onReviewComment?(.object(values)); self.handleReviewEscape()
        }
        rebuildReviewAnnotations(); window?.makeFirstResponder(draft.editor)
    }
    private func beginReview(_ target: DiffLineTarget, extending: Bool = false) {
        guard onReviewComment != nil, let file = list.diff.files.first(where: { $0.path == target.path }),
              let index = file.hunks.flatMap({ Array($0.lines) }).first(where: {
                  target.right ? list.diff.lines[$0].newNumber == target.newLine : list.diff.lines[$0].oldNumber == target.oldLine
              }) else { return }
        if (!extending && NSApp.currentEvent?.modifierFlags.contains(.shift) != true) || reviewStart?.path != target.path { reviewStart = (target.path, index) }
        let start = reviewStart?.line ?? index
        let id = UUID().uuidString.lowercased()
        let draft = editingReviewId == nil ? reviewDraft ?? DiffReviewAnnotationView() : DiffReviewAnnotationView()
        editingReviewId = nil; reviewDraft = draft
        draft.onCancel = { [weak self] in self?.handleReviewEscape() }
        draft.onSubmit = { [weak self] text in
            guard let self, let record = DiffReviewContext.record(diff: self.list.diff, path: target.path, start: start, end: index,
                text: text, section: self.selectedRunId?.rawValue ?? "diff", title: self.scopeButton.title ?? "Diff", id: id) else { return }
            self.onReviewComment?(record); self.handleReviewEscape()
        }
        reviewDraftAnchor = DiffAnnotation(path: target.path, right: target.right, line: target.right ? target.newLine : target.oldLine, id: id)
        rebuildReviewAnnotations()
        window?.makeFirstResponder(draft.editor)
    }
    public let list = DiffListView()
    private let scroll: ScrollAreaView
    private let fileTree = FileTreeView()
    private let treeTitle = LabelView("Files", font: DSFont.ui(12, weight: .medium))
    private let treeCount = LabelView("", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    private let treeExpansion = ButtonView(nil, icon: .chevronsDownUp, variant: .ghost, size: .iconXs)
    private let treeScroll: ScrollAreaView
    private let find = InputView(placeholder: "Find", size: .compact)
    private let findCount = LabelView("", font: DSFont.ui(11))
    private let findCase = ToggleView("Aa", variant: .ghost, size: .sm)
    private let findWord = ToggleView("Ab", variant: .ghost, size: .sm)
    private let findRegex = ToggleView(".*", variant: .ghost, size: .sm)
    private let findPrevious = ButtonView(nil, icon: .arrowUp, variant: .ghost, size: .iconSm)
    private let findNext = ButtonView(nil, icon: .arrowDown, variant: .ghost, size: .iconSm)
    private let findClose = ButtonView(nil, icon: .x, variant: .ghost, size: .iconSm)
    private var findControls: [NSView] { [find, findCount, findCase, findWord, findRegex, findPrevious, findNext, findClose] }
    private var searchMatches: [DiffPanelSearch.Match] = []
    private var searchIndex = 0
    private let scopeButton = ButtonView("Latest turn", variant: .secondary, size: .xs)
    private let totals = DiffStatView()
    private let refreshButton = ButtonView(nil, icon: .refreshCw, variant: .ghost, size: .iconSm)
    private let collapseButton = ButtonView(nil, icon: .chevronsUpDown, variant: .ghost, size: .iconSm)
    private let layoutToggle = ToggleGroupView(variant: .segmented, items: [(nil, .rows3), (nil, .columns2)], selected: 0)
    private let wrapToggle = ToggleView(nil, icon: .textWrap, variant: .ghost, size: .sm, pressed: true)
    private let whitespaceToggle = ToggleView(nil, icon: .pilcrow, variant: .ghost, size: .sm, pressed: true)
    private let treeToggle = ToggleView(nil, icon: .folderTree, variant: .ghost, size: .sm)
    let message = LabelView("", font: DSFont.ui(12), color: Themed.color(\.mutedForeground, 0.7))
    /// The failed request's message above the empty state (DiffPanel.tsx:1093-1097, `text-2xs text-error/80`).
    let errorLine = LabelView("", font: DSFont.ui(11), color: Themed.color(\.error, 0.8))
    private let headerBorder = CALayer()

    private var summaries: [TurnDiffSummary] = []
    private var selectedRunId: RunId?
    /// A run asked for before its summary arrived.
    private var requestedRunId: RunId?
    private var pendingFile: String?
    private var loadTask: Task<Void, Never>?
    private var hasDiff = false

    public override init(frame frameRect: NSRect) {
        scroll = ScrollAreaView(documentView: list)
        treeScroll = ScrollAreaView(documentView: fileTree)
        super.init(frame: frameRect)
        scopeButton.trailingIcon = .chevronDown
        scopeButton.iconSize = 14
        scopeButton.iconColor = Themed.color(\.secondaryForeground, 0.7)
        scopeButton.scalesWhenPressed = false
        scopeButton.action = { [weak self] in self?.showScopeMenu() }
        for button in [refreshButton, collapseButton] { button.iconSize = 14 }
        refreshButton.isHidden = true
        refreshButton.action = { [weak self] in self?.reload() }
        collapseButton.action = { [weak self] in
            guard let self else { return }
            list.setAllCollapsed(!list.allCollapsed)
        }
        layoutToggle.items.forEach { $0.iconSize = 14 }
        layoutToggle.invalidateIntrinsicContentSize()
        layoutToggle.onChange = { [weak self] index in
            guard let self else { return }
            // A segmented group always keeps one value (T3 ignores an empty selection).
            guard let index else { layoutToggle.selectedIndex = layoutStyle == .unified ? 0 : 1; return }
            layoutStyle = index == 0 ? .unified : .split
            // The toolbar toggle writes the `diffLayout` setting (DiffPanel.tsx:982-986).
            ClientSettingsStore.shared.update(["diffLayout": .string(index == 0 ? "stacked" : "split")])
        }
        for toggle in [wrapToggle, whitespaceToggle, treeToggle] { toggle.iconSize = 14 }
        wrapToggle.onPressedChange = { [weak self] in self?.wrapLines = $0 }
        whitespaceToggle.onPressedChange = { [weak self] in self?.ignoreWhitespace = $0 }
        treeToggle.onPressedChange = { [weak self] shown in self?.treeScroll.isHidden = !shown; self?.needsLayout = true }
        treeScroll.isHidden = true
        treeExpansion.iconSize = 14
        treeExpansion.action = { [weak self] in
            guard let self else { return }
            _ = self.fileTree.model.setAllExpanded(!self.fileTree.model.allExpanded)
            self.needsLayout = true
        }
        list.onVisibleFile = { [weak self] path in self?.fileTree.selectedPath = path }
        fileTree.onOpenFile = { [weak self] path in self?.fileTree.selectedPath = path; self?.list.reveal(path: path) }
        findControls.forEach { $0.isHidden = true; addSubview($0) }
        for (toggle, label) in [(findCase, "Match case"), (findWord, "Match whole word"), (findRegex, "Use regular expression")] {
            toggle.setAccessibilityLabel(label)
            toggle.onPressedChange = { [weak self] _ in self?.search() }
        }
        findPrevious.setAccessibilityLabel("Previous match")
        findNext.setAccessibilityLabel("Next match")
        findClose.setAccessibilityLabel("Close find")
        findPrevious.action = { [weak self] in self?.stepSearch(-1) }
        findNext.action = { [weak self] in self?.stepSearch(1) }
        findClose.action = { [weak self] in self?.closeFind() }
        find.onChange = { [weak self] _ in self?.search() }
        find.onCommand = { [weak self] selector in
            guard let self else { return false }
            if selector == #selector(NSResponder.cancelOperation(_:)) { self.closeFind(); return true }
            if selector == #selector(NSResponder.insertNewline(_:)) {
                self.stepSearch(NSApp.currentEvent?.modifierFlags.contains(.shift) == true ? -1 : 1); return true
            }
            return false
        }
        list.onLineClick = { [weak self] in self?.beginReview($0) }
        list.onLineRange = { [weak self] start, end in
            self?.beginReview(start)
            self?.beginReview(end, extending: true)
        }
        list.onCollapsedChange = { [weak self] in self?.updateCollapseButton() }
        headerBorder.actions = ["frame": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]
        layer?.addSublayer(headerBorder)
        message.alignment = .center
        message.lineHeight = 16
        errorLine.lineHeight = 16.5
        [treeTitle, treeCount, treeExpansion, treeScroll, find, findCount, scroll, scopeButton, totals, refreshButton, collapseButton, layoutToggle, wrapToggle, whitespaceToggle, treeToggle, message, errorLine].forEach(addSubview)
        message.isHidden = true
        errorLine.isHidden = true
        totals.isHidden = true
        updateCollapseButton()
        applySettings(initial: true)
        settingsObserver = ClientSettingsStore.shared.observe { [weak self] keys in
            if keys.contains("diffLayout") { self?.applySettings(initial: false) }
            if keys.contains("diffColorScheme") {
                func repaint(_ view: NSView) { view.needsDisplay = true; view.subviews.forEach(repaint) }
                if let self { repaint(self) }
            }
        }
    }

    private var settingsObserver: Int?

    /// `diffLayout` follows the setting; `wordWrap` and `diffIgnoreWhitespace` seed the toggles once
    /// (`useState(settings.wordWrap)`, DiffPanel.tsx:203-206).
    private func applySettings(initial: Bool) {
        let c = ClientSettingsStore.shared.current
        layoutStyle = c.string("diffLayout") == "split" ? .split : .unified
        guard initial else { return }
        wrapLines = c.bool("wordWrap")
        ignoreWhitespace = c.bool("diffIgnoreWhitespace")
    }

    // MARK: Public API

    /// The thread's checkpoint summaries (`TurnDiffs.summaries(projection)`), any order.
    public func setSummaries(_ summaries: [TurnDiffSummary]) {
        self.summaries = TurnDiffs.sortedForPanel(summaries)
        if let requested = requestedRunId, self.summaries.contains(where: { $0.runId == requested }) {
            requestedRunId = nil
            if requested != selectedRunId || !hasDiff { selectedRunId = requested; reload() }
        } else if selectedRunId == nil || !self.summaries.contains(where: { $0.runId == selectedRunId }) {
            selectedRunId = self.summaries.first?.runId
            reload()
        }
        updateScopeLabel()
    }

    /// Selects a run (nil: the latest) and, once its diff is loaded, scrolls to `filePath`.
    /// This is what the changed files card's "Open diff" and file rows call (`onOpenTurnDiff`).
    public func open(runId: RunId?, filePath: String?) {
        let known = runId.flatMap { id in summaries.first { $0.runId == id }?.runId }
        if let runId, known == nil { requestedRunId = runId } // its summary is still on the way
        let target = known ?? summaries.first?.runId
        pendingFile = filePath
        if target != selectedRunId || !hasDiff {
            selectedRunId = target
            updateScopeLabel()
            reload()
        } else if let filePath {
            pendingFile = nil
            list.reveal(path: filePath, expand: false)
        }
    }

    /// Shows a patch directly, for previews, tests and git sources.
    public func showPatch(_ patch: String, scopeLabel: String? = nil, collapsed: Bool = true) {
        if let scopeLabel { scopeButton.title = scopeLabel; needsLayout = true }
        show(UnifiedDiff(patch), collapsed: collapsed)
    }

    /// File headers' counts: pierre's (turn diffs) or T3's aligned label (lazy git sources).
    public var statStyle: DiffStatStyle {
        get { list.statStyle }
        set { list.statStyle = newValue }
    }

    // MARK: Loading

    private var selectedSummary: TurnDiffSummary? { summaries.first { $0.runId == selectedRunId } }

    private func reload() {
        loadTask?.cancel()
        guard let summary = selectedSummary, let threadId, let loader else {
            if summaries.isEmpty, threadId != nil { showMessage("No completed turns yet.") }
            return
        }
        let request = TurnDiffs.request(threadId: threadId, summary: summary, ignoreWhitespace: ignoreWhitespace)
        if !hasDiff { showMessage("Loading checkpoint diff...") }
        loadTask = Task { [weak self] in
            do {
                let reply = try await loader(request)
                let parsed = await Task.detached(priority: .userInitiated) { UnifiedDiff(reply.diff) }.value
                guard !Task.isCancelled, let self else { return }
                if reply.diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.showMessage("No net changes in this selection.")
                } else {
                    self.show(parsed, collapsed: ClientSettingsStore.shared.current.bool("diffFilesCollapsed"))
                }
            } catch {
                // T3 shows the RPC error's message, then the no-patch state under it
                // (DiffPanel.tsx:1093-1117, state/query.ts:20-25). An interrupted latest run gets
                // "Failed to load turn diff": its checkpoint is past the server's turn count.
                guard !Task.isCancelled, let self else { return }
                let text = (error as? LocalizedError)?.errorDescription ?? ""
                self.showMessage("No patch available for this selection.",
                                 error: text.trimmingCharacters(in: .whitespaces).isEmpty ? "The environment request failed." : text)
            }
        }
    }

    private func show(_ diff: UnifiedDiff, collapsed: Bool) {
        hasDiff = true
        message.isHidden = true
        errorLine.isHidden = true
        scroll.isHidden = false
        list.annotations = []; reviewDraft = nil; reviewStart = nil; reviewDraftAnchor = nil; editingReviewId = nil
        list.setDiff(diff, collapsedByDefault: collapsed)
        rebuildReviewAnnotations()
        fileTree.changes = Dictionary(diff.files.map { ($0.path, $0.change) }, uniquingKeysWith: { a, b in a == b ? a : .change })
        fileTree.model = DiffPanelSearch.tree(diff)
        if !find.isHidden { search() }
        totals.setInline(additions: diff.additions, deletions: diff.deletions)
        totals.isHidden = diff.files.isEmpty
        updateCollapseButton()
        needsLayout = true
        if let file = pendingFile {
            pendingFile = nil
            layoutSubtreeIfNeeded()
            list.reveal(path: file, expand: false)
        }
    }

    private func showMessage(_ text: String, error: String? = nil) {
        hasDiff = false
        list.setDiff(UnifiedDiff(""))
        fileTree.model = FileTreeModel(); fileTree.changes = [:]
        searchMatches = []; searchIndex = 0
        message.text = text
        message.isHidden = false
        errorLine.text = error ?? ""
        errorLine.isHidden = error == nil
        scroll.isHidden = true
        totals.isHidden = true
        needsLayout = true
    }

    // MARK: Header

    private func updateScopeLabel() {
        guard let summary = selectedSummary else { return }
        scopeButton.title = summary.runId == summaries.first?.runId ? "Latest turn" : "Turn \(summary.checkpointTurnCount)"
        needsLayout = true
    }

    private func updateCollapseButton() {
        collapseButton.icon = list.allCollapsed ? .chevronsUpDown : .chevronsDownUp
        collapseButton.iconSize = 14
        collapseButton.setAccessibilityLabel(list.allCollapsed ? "Expand all files" : "Collapse all files")
    }

    /// "Latest turn" and a Turn submenu (DiffPanel.tsx:757-822). Git scopes are not offered yet.
    private func showScopeMenu() {
        guard !summaries.isEmpty else { return }
        let latest = summaries.first?.runId
        var turns: [MenuItem] = []
        for summary in summaries {
            var item = MenuItem("Turn \(summary.checkpointTurnCount)", kind: .radio(summary.runId == selectedRunId))
            item.closesOnClick = true
            item.action = { [weak self] in self?.open(runId: summary.runId, filePath: nil) }
            turns.append(item)
        }
        var latestItem = MenuItem("Latest turn", kind: .radio(selectedRunId == latest))
        latestItem.closesOnClick = true
        latestItem.action = { [weak self] in self?.open(runId: latest, filePath: nil) }
        MenuPopupView.show([latestItem, .submenu("Turn", turns)], from: scopeButton, placement: .dropdown)
    }

    public override var acceptsFirstResponder: Bool { true }
    public override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }

    public func showFind() {
        findControls.forEach { $0.isHidden = false }; search(); needsLayout = true
        window?.makeFirstResponder(find)
    }
    private func closeFind() {
        findControls.forEach { $0.isHidden = true }
        list.searchMatches = []; list.activeSearchMatch = nil
        needsLayout = true; window?.makeFirstResponder(list)
    }
    private func search() {
        searchMatches = DiffPanelSearch.matches(find.text, in: list.diff, caseSensitive: findCase.isPressed,
                                               wholeWord: findWord.isPressed, regex: findRegex.isPressed)
        searchIndex = 0; revealSearch()
    }
    private func stepSearch(_ direction: Int) {
        guard !searchMatches.isEmpty else { return }
        searchIndex = (searchIndex + direction + searchMatches.count) % searchMatches.count
        revealSearch()
    }
    private func revealSearch() {
        list.searchMatches = searchMatches
        list.activeSearchMatch = searchMatches.isEmpty ? nil : searchMatches[searchIndex]
        findPrevious.isEnabled = !searchMatches.isEmpty; findNext.isEnabled = !searchMatches.isEmpty
        findCount.text = searchMatches.isEmpty ? "No results" : "\(searchIndex + 1) of \(searchMatches.count)"
        if !searchMatches.isEmpty { list.revealSearch(searchMatches[searchIndex]) }
    }

    private var headerHeight: CGFloat { inlineHeader ? 28 : 40 }
    private var bodyTop: CGFloat { (inlineHeader ? 28 + 12 : 40) + bodyOffset + (find.isHidden ? 0 : 36) }
    /// For the fidelity test: the reference captures' tab strip ends at a half pixel and the list
    /// lands on the next whole one, 0.5pt lower than the header row's offset says.
    var bodyOffset: CGFloat = 0

    public override func layout() {
        super.layout()
        let h = headerHeight
        let scopeWidth = min(scopeButton.intrinsicContentSize.width, max(0, bounds.width / 2))
        // Measured in references 09 and 10: 8px each side in the right panel's tab mode.
        let pad: CGFloat = inlineHeader ? 8 : 16
        scopeButton.frame = NSRect(x: pad, y: (h - 24) / 2, width: scopeWidth, height: 24)
        // Right cluster: `gap-1`, laid out from the right edge.
        var x = bounds.width - pad
        func place(_ view: NSView, width: CGFloat, height: CGFloat) {
            x -= width
            view.frame = NSRect(x: x, y: ((h - height) / 2 * 2).rounded() / 2, width: width, height: height)
            x -= 4
        }
        place(treeToggle, width: 28, height: 28)
        place(whitespaceToggle, width: 28, height: 28)
        place(wrapToggle, width: 28, height: 28)
        let group = layoutToggle.intrinsicContentSize
        place(layoutToggle, width: group.width, height: group.height)
        place(collapseButton, width: 28, height: 28)
        if showsRefresh { place(refreshButton, width: 28, height: 28) }
        if !totals.isHidden {
            x -= 4 // `mr-1`
            place(totals, width: totals.preferredWidth, height: h)
        }
        headerBorder.frame = CGRect(x: 0, y: h - 1, width: bounds.width, height: 1)
        headerBorder.isHidden = inlineHeader
        find.frame = NSRect(x: 8, y: headerHeight + 4, width: max(32, bounds.width - 266), height: 28)
        findCount.frame = NSRect(x: bounds.width - 166, y: headerHeight + 8, width: 72, height: 20)
        for (i, control) in [findCase, findWord, findRegex].enumerated() {
            control.frame = NSRect(x: bounds.width - 258 + CGFloat(i) * 30, y: headerHeight + 4, width: 28, height: 28)
        }
        for (i, control) in [findPrevious, findNext, findClose].enumerated() {
            control.frame = NSRect(x: bounds.width - 92 + CGFloat(i) * 28, y: headerHeight + 4, width: 28, height: 28)
        }
        let treeWidth: CGFloat = treeScroll.isHidden ? 0 : min(220, bounds.width * 0.35)
        for view in [treeTitle, treeCount, treeExpansion] { view.isHidden = treeScroll.isHidden }
        treeTitle.frame = NSRect(x: 12, y: bodyTop + 6, width: 60, height: 16)
        treeCount.text = String(fileTree.model.directories.values.flatMap { $0 }.filter { !$0.isDirectory }.count)
        treeCount.frame = NSRect(x: treeWidth - 62, y: bodyTop + 6, width: 24, height: 16)
        treeExpansion.frame = NSRect(x: treeWidth - 32, y: bodyTop + 2, width: 24, height: 24)
        treeExpansion.icon = fileTree.model.allExpanded ? .chevronsDownUp : .chevronsUpDown
        treeExpansion.toolTip = fileTree.model.allExpanded ? "Collapse all folders" : "Expand all folders"
        treeExpansion.setAccessibilityLabel(treeExpansion.toolTip)
        treeExpansion.isHidden = treeScroll.isHidden || fileTree.model.directoryPaths.isEmpty
        treeScroll.frame = NSRect(x: 0, y: bodyTop + 40, width: treeWidth, height: max(0, bounds.height - bodyTop - 40))
        scroll.frame = NSRect(x: treeWidth, y: bodyTop, width: bounds.width - treeWidth, height: max(0, bounds.height - bodyTop))
        // The error paragraph (`px-3`, `mb-2`) takes its height off the top of the centered area.
        errorLine.frame = NSRect(x: 12, y: bodyTop, width: max(0, bounds.width - 24), height: 16.5)
        let messageTop = bodyTop + (errorLine.isHidden ? 0 : 16.5 + 8)
        message.frame = NSRect(x: 20, y: messageTop + (bounds.height - messageTop - 16) / 2, width: max(0, bounds.width - 40), height: 16)
    }

    public override func updateLayer() {
        layer?.backgroundColor = Themed.color(\.background).cgColor(in: self)
        headerBorder.backgroundColor = Themed.color(\.border, 0.6).cgColor(in: self)
    }
}
