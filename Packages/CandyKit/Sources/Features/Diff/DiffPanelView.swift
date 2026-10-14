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
            shownSection = nil
            gitSource = nil
            gitResultShown = false
            refreshedSummary = nil
            // A thread change shows Changes (ChatView.tsx:2304-2313).
            gitScope = gitLoader == nil ? nil : .branch
            updateScopeLabel()
        }
    }
    public var loader: Loader?

    // MARK: Git scopes

    /// T3's Changes (`branch`, the branch range against its base) and Uncommitted (`unstaged`, the working
    /// tree) scopes (diffPanelStore.ts, DiffPanel.tsx:289-412). The default selection.
    public enum GitScope: String, Sendable { case branch, unstaged }
    /// `review.getDiffPreview` for a checkout. Without one the panel shows turn diffs only.
    public typealias GitLoader = @Sendable (_ cwd: String, _ baseRef: String?, _ ignoreWhitespace: Bool) async throws -> ReviewDiffPreview
    /// `vcs.listRefs` with `refKind` local or remote and `includeMatchingRemoteRefs`, 100 refs.
    public typealias RefLoader = @Sendable (_ cwd: String, _ remote: Bool) async -> [VcsRef]
    public var gitLoader: GitLoader? {
        didSet {
            guard (gitLoader == nil) != (oldValue == nil) else { return }
            gitScope = gitLoader == nil ? nil : .branch
            updateScopeLabel()
        }
    }
    public var refLoader: RefLoader?
    /// The thread's checkout (`worktreePath ?? workspaceRoot`, DiffPanel.tsx:238).
    public var workspaceRoot: String?
    /// The shown git scope, nil while a turn shows.
    public private(set) var gitScope: GitScope? { didSet { if gitScope != oldValue { gitResultShown = false } } }
    public var selectsGitScopes: Bool { gitLoader != nil }
    private var gitSource: ReviewDiffPreview.Source?
    private var gitCwd: String?
    /// The shown git scope has an answer on screen (a diff, an empty state or an error).
    private var gitResultShown = false
    /// The section whose diff shows: an unsent comment survives a refresh of the same section, as T3 keys its
    /// annotation view by section (DiffPanel.tsx:1174-1175).
    private var shownSection: String?
    private let compareHead = LabelView("", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    private let compareArrow = IconView(name: .arrowRight, size: 14, strokeColor: Themed.color(\.mutedForeground, 0.7))
    private let baseRefButton = ButtonView("", variant: .ghostMuted, size: .xs).menuTrigger()
    private let truncatedNotice = LabelView("", font: DSFont.ui(11), color: Themed.color(\.mutedForeground))
    private let truncatedBar = CALayer(), truncatedBottom = CALayer()
    private var focusObserver: NSObjectProtocol?
    private var refreshedSummary: RunId?
    private static let baseRefsKey = "t3code.diffBranchBaseRefs"

    /// `selectBranchBaseRef`, kept per thread across relaunches like T3's `branchBaseRefByThreadKey`.
    private var baseRef: String? {
        get { threadId.flatMap { (UserDefaults.standard.dictionary(forKey: Self.baseRefsKey) as? [String: String])?[$0.rawValue] } }
        set {
            guard let threadId else { return }
            var all = UserDefaults.standard.dictionary(forKey: Self.baseRefsKey) as? [String: String] ?? [:]
            all[threadId.rawValue] = newValue?.trimmingCharacters(in: .whitespaces).isEmpty == false ? newValue : nil
            UserDefaults.standard.set(all, forKey: Self.baseRefsKey)
        }
    }

    /// `selectGitScope`: generic openings and proactive panels show Changes.
    public func selectGitScope(_ scope: GitScope) {
        guard gitLoader != nil else { return }
        let changed = gitScope != scope
        gitScope = scope
        pendingFile = nil; requestedRunId = nil
        updateScopeLabel()
        if changed || !gitResultShown { reload() }
    }

    /// The review section and its title (DiffPanel.tsx:313-325): `turn:<id>` and "Turn n", or the git scope.
    private var reviewSection: (id: String, title: String) {
        switch gitScope {
        case .branch: ("branch", "Changes")
        case .unstaged: ("unstaged", "Uncommitted")
        case nil:
            if let summary = selectedSummary { ("turn:\(summary.runId.rawValue)", "Turn \(summary.checkpointTurnCount)") }
            else { ("diff", scopeButton.title ?? "Diff") }
        }
    }
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
        let section = reviewSection.id
        // Comments saved before sections took T3's `turn:` prefix still anchor on their turn.
        let legacy = gitScope == nil ? selectedRunId?.rawValue : nil
        let records = reviewComments.filter {
            let id = $0["sectionId"]?.stringValue
            return (id == section || (legacy != nil && id == legacy)) && $0["contextId"]?.stringValue != editingReviewId
        }
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
        // An open comment turns the gutter and line selection off until it is sent or cancelled
        // (`enableGutterUtility: !hasOpenComment`, AnnotatableCodeView.tsx:251-275).
        guard extending || reviewDraft == nil else { return }
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
        // The line indices belong to the diff on screen now; a refresh can replace it before the comment is sent.
        let diff = list.diff, section = reviewSection
        draft.onSubmit = { [weak self] text in
            guard let self, let record = DiffReviewContext.record(diff: diff, path: target.path, start: start, end: index,
                text: text, section: section.id, title: section.title, id: id) else { return }
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
    /// The find widget floating over the files (@pierre/diffs' search panel).
    let findWidget = DiffFindWidget()
    private var find: InputView { findWidget.field }
    private var searchMatches: [DiffPanelSearch.Match] = []
    private var searchIndex = 0
    private let scopeButton = ButtonView("Latest turn", variant: .secondary, size: .xs).menuTrigger()
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
        scroll = ScrollAreaView(documentView: list, scrollbars: .native) // `overflow-auto` (DiffPanel.tsx:1178)
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
        findWidget.isHidden = true
        for toggle in [findWidget.matchCase, findWidget.wholeWord, findWidget.regex] {
            toggle.action = { [weak self, weak toggle] in toggle?.isPressed.toggle(); self?.search() }
        }
        findWidget.previous.action = { [weak self] in self?.stepSearch(-1) }
        findWidget.next.action = { [weak self] in self?.stepSearch(1) }
        findWidget.close.action = { [weak self] in self?.closeFind() }
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
        [treeTitle, treeCount, treeExpansion, treeScroll, scroll, scopeButton, totals, refreshButton, collapseButton, layoutToggle, wrapToggle, whitespaceToggle, treeToggle, message, errorLine,
         compareHead, compareArrow, baseRefButton, truncatedNotice, findWidget].forEach(addSubview)
        baseRefButton.trailingIcon = .chevronDown
        baseRefButton.iconSize = 14
        baseRefButton.scalesWhenPressed = false
        baseRefButton.action = { [weak self] in self?.showBaseRefMenu() }
        refreshButton.setAccessibilityLabel("Refresh diff")
        refreshButton.toolTip = "Refresh diff"
        truncatedBar.actions = ["frame": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]
        layer?.addSublayer(truncatedBar); truncatedBar.addSublayer(truncatedBottom)
        truncatedBottom.actions = truncatedBar.actions
        truncatedNotice.lineHeight = 16.5
        [compareHead, compareArrow, baseRefButton, truncatedNotice].forEach { $0.isHidden = true }
        truncatedBar.isHidden = true
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
        if gitScope != nil {
            // A finished turn changed the checkout: the git scope reads it again (`useWorkspaceMutationRefresh`).
            let latest = self.summaries.first?.runId
            if !gitResultShown, loadTask == nil { refreshedSummary = latest; reload() }
            else if latest != refreshedSummary { refreshedSummary = latest; if gitResultShown { reload() } }
            if selectedRunId == nil || !self.summaries.contains(where: { $0.runId == selectedRunId }) { selectedRunId = latest }
            return
        }
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
        let fromGit = gitScope != nil
        gitScope = nil
        if target != selectedRunId || !hasDiff || fromGit {
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
        loadTask = nil
        if let gitScope { reloadGit(gitScope); return }
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

    /// `review.getDiffPreview` for the checkout, then the scope's source: `branch-range` for Changes,
    /// `working-tree` for Uncommitted (DiffPanel.tsx:342-412, 1086-1117).
    private func reloadGit(_ scope: GitScope) {
        guard let gitLoader, let cwd = workspaceRoot else {
            showMessage("No patch available for this selection.")
            return
        }
        let baseRef = scope == .branch ? self.baseRef : nil
        let whitespace = ignoreWhitespace
        // A refresh keeps what shows until the answer arrives.
        if !gitResultShown { showMessage(scope == .unstaged ? "Loading uncommitted changes..." : "Loading changes...") }
        refreshButton.toolTip = "Refreshing diff…"
        refreshButton.setAccessibilityLabel("Refreshing diff")
        loadTask = Task { [weak self] in
            var parsed: UnifiedDiff?
            var source: ReviewDiffPreview.Source?
            var failure: String?
            do {
                let preview = try await gitLoader(cwd, baseRef, whitespace)
                source = preview.sources.first { $0.kind == (scope == .unstaged ? "working-tree" : "branch-range") }
                if let source {
                    parsed = await Task.detached(priority: .userInitiated) { UnifiedDiff(source.diff) }.value
                }
                if !Task.isCancelled, let self { self.gitCwd = preview.cwd }
            } catch {
                let text = (error as? LocalizedError)?.errorDescription ?? ""
                failure = text.trimmingCharacters(in: .whitespaces).isEmpty ? "The environment request failed." : text
            }
            guard !Task.isCancelled, let self, self.gitScope == scope else { return }
            self.loadTask = nil
            self.refreshButton.toolTip = "Refresh diff"
            self.refreshButton.setAccessibilityLabel("Refresh diff")
            self.gitSource = source
            self.gitResultShown = true
            self.updateScopeLabel()
            if let failure {
                self.showMessage("No patch available for this selection.", error: failure)
            } else if let source, let parsed {
                if source.diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.showMessage("No net changes in this selection.")
                } else {
                    self.show(parsed, collapsed: ClientSettingsStore.shared.current.bool("diffFilesCollapsed"))
                }
            } else {
                self.showMessage("No patch available for this selection.")
            }
        }
    }

    private func show(_ diff: UnifiedDiff, collapsed: Bool) {
        hasDiff = true
        message.isHidden = true
        errorLine.isHidden = true
        // ponytail: a truncated source shows its partial patch; T3 loads each file's patch on demand
        // (useReviewFilePatches) when the server sends complete file stats. Port it if large branches bite.
        let truncated = gitScope != nil && gitSource?.truncated == true
        truncatedNotice.text = "This preview exceeds the size limit. Changes shown are incomplete."
            + (gitSource?.files != nil ? " Totals include all changes." : "")
        truncatedNotice.isHidden = !truncated
        truncatedBar.isHidden = !truncated
        // An unsent comment stays when the same section reloads (a refresh), else it goes.
        let section = reviewSection.id
        let keepDraft = section == shownSection && reviewDraft != nil
        shownSection = section
        if !keepDraft { reviewDraft = nil; reviewStart = nil; reviewDraftAnchor = nil; editingReviewId = nil }
        scroll.isHidden = false
        list.annotations = []
        list.setDiff(diff, collapsedByDefault: collapsed)
        rebuildReviewAnnotations()
        fileTree.changes = Dictionary(diff.files.map { ($0.path, $0.change) }, uniquingKeysWith: { a, b in a == b ? a : .change })
        fileTree.model = DiffPanelSearch.tree(diff)
        if !find.isHidden { search() }
        // A truncated source's complete file stats give the totals (`diffLineStat`).
        if truncated, let files = gitSource?.files {
            totals.setInline(additions: files.reduce(0) { $0 + $1.additions }, deletions: files.reduce(0) { $0 + $1.deletions })
        } else {
            totals.setInline(additions: diff.additions, deletions: diff.deletions)
        }
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
        truncatedNotice.isHidden = true
        truncatedBar.isHidden = true
        needsLayout = true
    }

    // MARK: Header

    private func updateScopeLabel() {
        // `selectedScopeLabel` (DiffPanel.tsx:302-310), and the branch range's `head → base` (:810-850).
        showsRefresh = gitScope != nil
        let compare = gitScope == .branch ? gitSource.flatMap { s in s.baseRef.map { (s.headRef ?? "HEAD", $0) } } : nil
        compareHead.text = compare?.0 ?? ""
        compareHead.toolTip = compare.map { "\($0.0) → \($0.1)" }
        baseRefTitle = compare?.1 ?? ""
        baseRefButton.setAccessibilityLabel(compare.map { "Change comparison target. Currently \($0.1)" } ?? "")
        [compareHead, compareArrow, baseRefButton].forEach { $0.isHidden = compare == nil }
        needsLayout = true
        switch gitScope {
        case .branch: scopeButton.title = "Changes"; return
        case .unstaged: scopeButton.title = "Uncommitted"; return
        case nil: break
        }
        guard let summary = selectedSummary else { return }
        scopeButton.title = summary.runId == summaries.first?.runId ? "Latest turn" : "Turn \(summary.checkpointTurnCount)"
    }

    /// The comparison target menu: Automatic, then the local branches paired with their remotes and the
    /// remote-only refs (DiffPanel.tsx:826-920).
    // ponytail: a plain menu without the search field and the per-branch local/remote switch; a choice picks
    // its local branch when it has one. Port the combobox if users compare against remote branches often.
    private func showBaseRefMenu() {
        guard let refLoader, let cwd = gitCwd ?? workspaceRoot else { return }
        let head = gitSource?.headRef, selected = baseRef
        Task { [weak self] in
            async let local = refLoader(cwd, false)
            async let remote = refLoader(cwd, true)
            let choices = DiffBaseRefChoice.build(local: await local.filter { $0.name != head }, remote: await remote)
            guard let self, self.gitScope == .branch, self.window != nil else { return }
            var automatic = MenuItem("Automatic", kind: .radio(selected == nil))
            automatic.closesOnClick = true
            automatic.action = { [weak self] in self?.selectBaseRef(nil) }
            let items = [automatic] + choices.map { choice -> MenuItem in
                let value = choice.value(selected: selected)
                var item = MenuItem(choice.label, kind: .radio(value == selected))
                item.closesOnClick = true
                item.action = { [weak self] in self?.selectBaseRef(value) }
                return item
            }
            MenuPopupView.show(items, from: self.baseRefButton, placement: .dropdown)
        }
    }

    private var baseRefTitle = ""

    /// The xs button's label font (12px medium).
    private static func textWidth(_ text: String) -> CGFloat {
        TextLine(NSAttributedString(string: text, attributes: [.font: DSFont.ui(12, weight: .medium)])).width
    }

    /// `truncate`: the text cut at the end with an ellipsis to fit `width`.
    private static func truncate(_ text: String, to width: CGFloat) -> String {
        guard textWidth(text) > width else { return text }
        var cut = text
        while !cut.isEmpty, textWidth(cut + "…") > width { cut.removeLast() }
        return cut + "…"
    }

    private func selectBaseRef(_ ref: String?) {
        guard ref != baseRef else { return }
        baseRef = ref
        reload()
    }

    private func updateCollapseButton() {
        collapseButton.icon = list.allCollapsed ? .chevronsUpDown : .chevronsDownUp
        collapseButton.iconSize = 14
        collapseButton.setAccessibilityLabel(list.allCollapsed ? "Expand all files" : "Collapse all files")
    }

    /// "Latest turn" and a Turn submenu (DiffPanel.tsx:757-822). Git scopes are not offered yet.
    private func showScopeMenu() {
        guard gitLoader != nil || !summaries.isEmpty else { return }
        let latest = summaries.first?.runId
        let turnShown = gitScope == nil
        var turns: [MenuItem] = []
        for summary in summaries {
            var item = MenuItem("Turn \(summary.checkpointTurnCount)", kind: .radio(turnShown && summary.runId == selectedRunId))
            item.closesOnClick = true
            item.action = { [weak self] in self?.open(runId: summary.runId, filePath: nil) }
            turns.append(item)
        }
        var latestItem = MenuItem("Latest turn", kind: .radio(turnShown && latest != nil && selectedRunId == latest))
        latestItem.closesOnClick = true
        latestItem.action = { [weak self] in if let latest { self?.open(runId: latest, filePath: nil) } }
        var items = [latestItem]
        if gitLoader != nil {
            var changes = MenuItem("Changes", kind: .radio(gitScope == .branch))
            changes.closesOnClick = true
            changes.action = { [weak self] in self?.selectGitScope(.branch) }
            var uncommitted = MenuItem("Uncommitted", kind: .radio(gitScope == .unstaged))
            uncommitted.closesOnClick = true
            uncommitted.action = { [weak self] in self?.selectGitScope(.unstaged) }
            items = [changes, uncommitted, latestItem]
        }
        MenuPopupView.show(items + [.submenu("Turn", turns)], from: scopeButton, placement: .dropdown)
    }

    /// A git scope reads the checkout again when the window comes forward (`refreshOnFocus`, DiffPanel.tsx:512-517).
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let focusObserver { NotificationCenter.default.removeObserver(focusObserver); self.focusObserver = nil }
        guard let window else { return }
        focusObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.gitScope != nil, self.gitResultShown, self.loadTask == nil, !self.isHiddenOrHasHiddenAncestor else { return }
                self.reload()
            }
        }
    }

    public override var acceptsFirstResponder: Bool { true }
    public override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }

    public func showFind() {
        findWidget.isHidden = false; search(); needsLayout = true
        window?.makeFirstResponder(find)
    }
    private func closeFind() {
        findWidget.isHidden = true
        list.searchMatches = []; list.activeSearchMatch = nil
        needsLayout = true; window?.makeFirstResponder(list)
    }
    private func search() {
        searchMatches = DiffPanelSearch.matches(find.text, in: list.diff, caseSensitive: findWidget.matchCase.isPressed,
                                               wholeWord: findWidget.wholeWord.isPressed, regex: findWidget.regex.isPressed)
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
        findWidget.hasMatches = !searchMatches.isEmpty
        findWidget.countText = searchMatches.isEmpty ? "No results" : "\(searchIndex + 1) of \(searchMatches.count)"
        if !searchMatches.isEmpty { list.revealSearch(searchMatches[searchIndex]) }
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
        // `head → base` after the scope menu (`gap-3`): each ref `max-w-48`, `gap-2`, a 14px arrow at 70%.
        if gitScope == .branch, !baseRefTitle.isEmpty {
            // Both refs shrink with the room left (`min-w-0` in a `flex-1` row); the button's title truncates.
            var left = scopeButton.frame.maxX + 12
            let room = x - left - 8 - 14 - 8
            let chrome = baseRefButton.intrinsicContentSize.width - Self.textWidth(baseRefButton.title ?? "")
            let head = min(192, compareHead.intrinsicContentSize.width), base = min(192, chrome + Self.textWidth(baseRefTitle))
            let scale = min(1, max(0, room) / max(1, head + base))
            let fits = room >= chrome + 24
            [compareHead, compareArrow, baseRefButton].forEach { $0.isHidden = !fits }
            if fits {
                let headWidth = (head * scale).rounded(.up), baseWidth = (base * scale).rounded(.up)
                compareHead.frame = NSRect(x: left, y: (h - 16) / 2, width: headWidth, height: 16)
                left += headWidth + 8
                compareArrow.frame = NSRect(x: left, y: (h - 14) / 2, width: 14, height: 14)
                left += 14 + 8
                let title = scale < 1 ? Self.truncate(baseRefTitle, to: baseWidth - chrome) : baseRefTitle
                if baseRefButton.title != title { baseRefButton.title = title }
                baseRefButton.frame = NSRect(x: left, y: (h - 24) / 2, width: baseWidth, height: 24)
            }
        }
        headerBorder.frame = CGRect(x: 0, y: h - 1, width: bounds.width, height: 1)
        headerBorder.isHidden = inlineHeader
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
        // The size-limit notice: `border-b border-border/70 bg-muted/40 px-3 py-1.5 text-2xs` over the files.
        let notice: CGFloat = truncatedNotice.isHidden ? 0 : 6 + 16.5 + 6 + 1
        truncatedBar.frame = CGRect(x: treeWidth, y: bodyTop, width: bounds.width - treeWidth, height: notice)
        truncatedBottom.frame = CGRect(x: 0, y: notice - 1, width: bounds.width - treeWidth, height: 1)
        truncatedNotice.frame = NSRect(x: treeWidth + 12, y: bodyTop + 6, width: max(0, bounds.width - treeWidth - 24), height: 16.5)
        scroll.frame = NSRect(x: treeWidth, y: bodyTop + notice, width: bounds.width - treeWidth, height: max(0, bounds.height - bodyTop - notice))
        // `[data-search-panel]`: sticky 32pt down the scroller plus `top: 8px`, 16pt in from its end plus `right: 16px`.
        let widget = findWidget.preferredSize
        findWidget.frame = NSRect(x: scroll.frame.maxX - 32 - widget.width + DiffFindWidget.overhang,
                                  y: scroll.frame.minY + 40 - DiffFindWidget.overhang, width: widget.width, height: widget.height)
        // The error paragraph (`px-3`, `mb-2`) takes its height off the top of the centered area.
        errorLine.frame = NSRect(x: 12, y: bodyTop, width: max(0, bounds.width - 24), height: 16.5)
        let messageTop = bodyTop + (errorLine.isHidden ? 0 : 16.5 + 8)
        message.frame = NSRect(x: 20, y: messageTop + (bounds.height - messageTop - 16) / 2, width: max(0, bounds.width - 40), height: 16)
    }

    public override func updateLayer() {
        layer?.backgroundColor = WindowGlass.ground.cgColor(in: self)
        headerBorder.backgroundColor = Themed.color(\.border, 0.6).cgColor(in: self)
        // `bg-muted/40` with the 1px `border-border/70` along its bottom.
        truncatedBar.backgroundColor = Themed.color(\.muted, 0.4).cgColor(in: self)
        truncatedBottom.backgroundColor = Themed.color(\.border, 0.7).cgColor(in: self)
    }
}
