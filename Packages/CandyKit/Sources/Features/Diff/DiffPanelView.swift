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

    public let list = DiffListView()
    private let scroll: ScrollAreaView
    private let scopeButton = ButtonView("Latest turn", variant: .secondary, size: .xs)
    private let totals = DiffStatView()
    private let refreshButton = ButtonView(nil, icon: .refreshCw, variant: .ghost, size: .iconSm)
    private let collapseButton = ButtonView(nil, icon: .chevronsUpDown, variant: .ghost, size: .iconSm)
    private let layoutToggle = ToggleGroupView(variant: .segmented, items: [(nil, .rows3), (nil, .columns2)], selected: 0)
    private let wrapToggle = ToggleView(nil, icon: .textWrap, variant: .ghost, size: .sm, pressed: true)
    private let whitespaceToggle = ToggleView(nil, icon: .pilcrow, variant: .ghost, size: .sm, pressed: true)
    private let treeToggle = ToggleView(nil, icon: .folderTree, variant: .ghost, size: .sm)
    private let message = LabelView("", font: DSFont.ui(12), color: Themed.color(\.mutedForeground, 0.7))
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
        }
        for toggle in [wrapToggle, whitespaceToggle, treeToggle] { toggle.iconSize = 14 }
        wrapToggle.onPressedChange = { [weak self] in self?.wrapLines = $0 }
        whitespaceToggle.onPressedChange = { [weak self] in self?.ignoreWhitespace = $0 }
        // ponytail: the file tree aside (pierre trees) is not built; the toggle only shows state.
        // Build DiffFileTree when the tree is wanted (T3 keeps it off by default).
        list.onCollapsedChange = { [weak self] in self?.updateCollapseButton() }
        headerBorder.actions = ["frame": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]
        layer?.addSublayer(headerBorder)
        message.alignment = .center
        message.lineHeight = 16
        [scroll, scopeButton, totals, refreshButton, collapseButton, layoutToggle, wrapToggle, whitespaceToggle, treeToggle, message].forEach(addSubview)
        message.isHidden = true
        totals.isHidden = true
        updateCollapseButton()
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
                    self.show(parsed, collapsed: true)
                }
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.showMessage((error as? LocalizedError)?.errorDescription ?? "Failed to load diff: \(error)")
            }
        }
    }

    private func show(_ diff: UnifiedDiff, collapsed: Bool) {
        hasDiff = true
        message.isHidden = true
        scroll.isHidden = false
        list.setDiff(diff, collapsedByDefault: collapsed)
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

    private func showMessage(_ text: String) {
        hasDiff = false
        message.text = text
        message.isHidden = false
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
            item.action = { [weak self] in self?.open(runId: summary.runId, filePath: nil) }
            turns.append(item)
        }
        var latestItem = MenuItem("Latest turn", kind: .radio(selectedRunId == latest))
        latestItem.action = { [weak self] in self?.open(runId: latest, filePath: nil) }
        MenuPopupView.show([latestItem, .submenu("Turn", turns)], from: scopeButton, placement: .dropdown)
    }

    private var headerHeight: CGFloat { inlineHeader ? 28 : 40 }
    private var bodyTop: CGFloat { (inlineHeader ? 28 + 12 : 40) + bodyOffset }
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
        scroll.frame = NSRect(x: 0, y: bodyTop, width: bounds.width, height: max(0, bounds.height - bodyTop))
        message.frame = NSRect(x: 20, y: bodyTop + (bounds.height - bodyTop - 16) / 2, width: max(0, bounds.width - 40), height: 16)
    }

    public override func updateLayer() {
        layer?.backgroundColor = Themed.color(\.background).cgColor(in: self)
        headerBorder.backgroundColor = Themed.color(\.border, 0.6).cgColor(in: self)
    }
}
