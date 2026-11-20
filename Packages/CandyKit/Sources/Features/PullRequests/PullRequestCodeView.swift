import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// The Code tab (PullRequestCodeTab.tsx): a `h-10` toolbar with the commit scope and the counts,
/// the conversations that sit on no line of the loaded diff (folded, counted), then the shared diff
/// list with a "Viewed" tick on each file header, review conversations and pending comments under
/// their lines, and a click in a line's gutter starting a review comment. The diff arrives in
/// slices (`nextCursor`); the next one is asked for as the end comes near (lines 620-640, 780-797).
public final class PullRequestCodeView: DSView {
    private let toolbarFill = CALayer()
    private let rule = CALayer()
    private let scope = ButtonView("All commits", variant: .secondary, size: .xs).menuTrigger()
    private let counts = LabelView("", font: DSFont.ui(12))
    private let list = DiffListView()
    private let scroll: ScrollAreaView
    private let status = LabelView("", font: DSFont.ui(12))
    private let footer = LabelView("", font: DSFont.ui(12))
    private let footerRetry = ButtonView("Retry", variant: .outline, size: .xs)
    private let orphanToggle = LinkLabel()
    /// "N test files hidden" after the file count, a link that shows them again (PullRequestCodeTab.tsx:1447-1454).
    private let hiddenTestsLink = LinkLabel()
    private let viewedCounts = LabelView("", font: DSFont.ui(12))
    /// "Hide test files" at the toolbar's end while the loaded diff has any (:1686-1703, #26730).
    private let hideTestsToggle = ToggleView(nil, icon: .flaskConicalOff, variant: .ghost, size: .sm, pressed: DiffHideTestFiles.value)
    /// Show or hide the file list, remembered (`t3code.pullRequestFileTreeOpen`, 4928 PullRequestCodeTab.tsx:190, 463, 1706-1723).
    private let treeToggle = ToggleView(nil, icon: .folderTree, variant: .ghost, size: .sm, pressed: UserDefaults.standard.bool(forKey: "t3code.pullRequestFileTreeOpen"))
    private var treeTooltip: TooltipController?
    /// The resizable list on the right, min(320, 40%), at least 192 (PullRequestCodeTab.tsx:1960-2003, #28244).
    private let filePane = FileListPane(sizing: .pullRequestCode, resizeLabel: "Resize PR Code files", listLabel: "Pull request files")
    private let loadMoreFiles = ButtonView("Load more files", variant: .outline, size: .xs)
    private var hideTestsTooltip: TooltipController?
    private var testFileCount = 0
    // Withheld files (#37007): left out of the paged diff, each loadable on its own.
    private var omitted: [String: (additions: Int, deletions: Int)] = [:]
    private var withheldReadable = false
    private var withheldLoaded: [String: String] = [:]
    private var withheldStatus: [String: PullRequestWithheldFileNotice.Status] = [:]
    private var withheldNotices: [String: PullRequestWithheldFileNotice] = [:]
    /// "Load diff" or "Retry" on a withheld file: read it with `path`.
    var onLoadWithheld: ((String) -> Void)?
    private var hiddenTestFileCount = 0
    private let orphanChevron = IconView(name: .chevronRight, size: 14)
    private let orphanRule = CALayer()
    private let orphanScroll: ScrollAreaView
    private let orphanDocument = DSView()
    /// `transition-transform`, `rotate-90` when open (PullRequestCodeTab.tsx:1488).
    private var orphansOpen = false { didSet { orphanChevron.setRotation(orphansOpen ? 90 : 0) } }
    private var commits: [PullRequestCommit] = []
    private var commit: String?
    private var paths: [String] = []
    private var states: [String: String]?
    private var overlay: [String: Bool] = [:]
    private var store: String?
    private var patches: [String] = []
    private var nextCursor: String?
    private var moreLoading = false
    private var moreError: String?
    // Review.
    private var detail: PullRequestDetail?
    private var reviewKey: String?
    private var actions: PullRequestReviewThreadActions?
    private var nowMs: Int64 = 0
    private var draft: (target: DiffLineTarget, view: PullRequestDraftCommentView)?
    private var threadCards: [String: PullRequestReviewThreadCardView] = [:]
    /// Conversations shown on their line. Open ones join when seen, so one resolved under the reader stays (#34644).
    private var shownThreads: Set<String> = []
    private var resolvedButtons: [String: PullRequestResolvedThreadsButton] = [:]
    private var orphanCards: [PullRequestReviewThreadCardView] = []
    private var reviewObserver: NSObjectProtocol?
    isolated deinit { if let reviewObserver { NotificationCenter.default.removeObserver(reviewObserver) } }
    var onCommit: ((String?) -> Void)?
    var onSetViewed: (([String], Bool) -> Void)?
    /// The file last marked viewed or not, where a shift-click's range starts. A new scope forgets it.
    private var viewedAnchor: String?
    /// The reader's own folds by path (`FileDiffFoldChoices`). A new scope forgets them (PullRequestCodeTab.tsx:494-500).
    private var foldChoices: [String: Bool] = [:]
    /// The next slice is wanted (`loadNextSlice`), or a failed one again.
    var onLoadMore: (() -> Void)?
    /// The first slice failed and "Try again" was pressed (`diffQuery.refresh`).
    var onRetry: (() -> Void)?
    var onOpenURL: ((String) -> Void)?
    /// The failure screen while the first slice failed (PullRequestCodeTab.tsx:1330-1339).
    private var unavailable: PullRequestDiffUnavailableView?
    private(set) lazy var scrollTarget = PullRequestScrollWatcher(scroll)

    public override init(frame frameRect: NSRect) {
        // `overflow-auto [scrollbar-gutter:stable]` and `max-h-64 overflow-auto` (PullRequestCodeTab.tsx:1572, :1503).
        scroll = ScrollAreaView(documentView: list, scrollbars: .native)
        orphanScroll = ScrollAreaView(documentView: orphanDocument, scrollbars: .native)
        super.init(frame: frameRect)
        for l in [toolbarFill, rule, orphanRule] { l.actions = ["frame": NSNull(), "bounds": NSNull(), "position": NSNull()]; layer?.addSublayer(l) }
        scope.trailingIcon = .chevronDown
        scope.iconSize = 14
        counts.lineHeight = 16
        status.lineHeight = 16
        status.alignment = .center
        footer.lineHeight = 16
        footer.alignment = .center
        orphanToggle.font = DSFont.ui(12)
        orphanToggle.underlines = false
        [scope, counts, hiddenTestsLink, viewedCounts, hideTestsToggle, treeToggle, filePane, scroll, status, footer, footerRetry, orphanToggle, orphanChevron, orphanScroll].forEach(addSubview)
        viewedCounts.lineHeight = 16
        hiddenTestsLink.font = DSFont.ui(12)
        hiddenTestsLink.underlines = false
        hiddenTestsLink.isHidden = true
        hiddenTestsLink.onClick = { [weak self] in self?.setHideTests(false) }
        hideTestsToggle.iconSize = 14
        hideTestsToggle.isHidden = true
        hideTestsToggle.setAccessibilityLabel("Hide test files")
        hideTestsTooltip = TooltipController.attach(to: hideTestsToggle, text: "Hide test files", placement: PopupPlacement(side: .top, align: .center, sideOffset: 4))
        hideTestsToggle.onPressedChange = { [weak self] in self?.setHideTests($0) }
        treeToggle.iconSize = 14
        treeTooltip = TooltipController.attach(to: treeToggle, text: treeToggle.isPressed ? "Hide file tree" : "Show file tree", placement: PopupPlacement(side: .top, align: .center, sideOffset: 4))
        treeToggle.setAccessibilityLabel(treeToggle.isPressed ? "Hide file tree" : "Show file tree")
        treeToggle.onPressedChange = { [weak self] open in
            guard let self else { return }
            UserDefaults.standard.set(open, forKey: "t3code.pullRequestFileTreeOpen")
            self.treeTooltip?.text = open ? "Hide file tree" : "Show file tree"
            self.treeToggle.setAccessibilityLabel(self.treeTooltip?.text)
            self.needsLayout = true
        }
        filePane.onWidthChange = { [weak self] in self?.needsLayout = true }
        filePane.tree.onOpenFile = { [weak self] path in self?.filePane.tree.selectedPath = path; self?.list.reveal(path: path) }
        list.onVisibleFile = { [weak self] path in self?.filePane.tree.selectedPath = path }
        loadMoreFiles.action = { [weak self] in self?.onLoadMore?() }
        scope.action = { [weak self] in self?.showScopeMenu() }
        footerRetry.action = { [weak self] in self?.onLoadMore?() }
        // `CollapsiblePanel` (PullRequestCodeTab.tsx:1500): the list slides open over 200 ms and the diff rides it.
        orphanToggle.onClick = { [weak self] in
            guard let self else { return }
            CollapseMotion.run(in: self, root: self) { self.orphansOpen.toggle(); self.needsLayout = true }
        }
        list.onSetViewed = { [weak self] path, viewed in
            guard let self else { return }
            let range = PullRequestDetailLogic.viewedRange(self.paths, path: path,
                                                          anchor: NSEvent.modifierFlags.contains(.shift) ? self.viewedAnchor : nil)
            self.viewedAnchor = path
            // The list folds the clicked file itself; the rest of the range folds the same way. With the setting off a
            // press drops the reader's fold, so the file follows its mark; with it on, the press is the choice (:1020-1026).
            let folded = self.defaultFold
            for p in (range.isEmpty ? [path] : range) { self.foldChoices[p] = folded == nil ? nil : viewed }
            for other in range where other != path { if let i = self.paths.firstIndex(of: other) { self.list.setCollapsed(i, viewed) } }
            self.onSetViewed?(range.isEmpty ? [path] : range, viewed)
        }
        list.onUserToggle = { [weak self] file, collapsed in
            guard let self, self.paths.indices.contains(file) else { return }
            self.foldChoices[self.paths[file]] = collapsed
        }
        list.annotationView = { [weak self] a in self?.annotationView(a) }
        list.onNearEnd = { [weak self] in
            guard let self, self.nextCursor != nil, !self.moreLoading, self.moreError == nil else { return }
            self.onLoadMore?()
        }
        reviewObserver = NotificationCenter.default.addObserver(forName: PullRequestReviewStore.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateAnnotations() }
        }
    }

    func reset() {
        commit = nil; paths = []; patches = []; nextCursor = nil; draft = nil; threadCards = [:]; viewedAnchor = nil; foldChoices = [:]
        omitted = [:]; withheldReadable = false; withheldLoaded = [:]; withheldStatus = [:]; withheldNotices = [:]
        list.annotations = []
        list.setDiff(UnifiedDiff(""))
    }

    /// The slices read so far, in order; `nextCursor` says more is owed.
    func set(patches: [String], loading: Bool, error: String?, nextCursor: String?, moreLoading: Bool, moreError: String?,
             commit: String?, commits: [PullRequestCommit]) {
        self.commits = commits.sorted { (T3Timestamp($0.committedDate).epochMs ?? 0) > (T3Timestamp($1.committedDate).epochMs ?? 0) }
        if commit != self.commit { draft = nil; viewedAnchor = nil; foldChoices = [:]; withheldNotices = [:] }
        self.commit = commit
        self.nextCursor = nextCursor
        self.moreLoading = moreLoading
        self.moreError = moreError
        scope.title = commit.flatMap { oid in commits.first { $0.oid == oid }?.messageHeadline } ?? "All commits"
        scope.isHidden = commits.isEmpty
        if patches != self.patches {
            self.patches = patches
            rebuildDiff()
            // An appended slice keeps what the reader folded: the choices are by path.
            applyFolds()
        }
        let empty = !loading && error == nil && patches.allSatisfy(\.isEmpty) && nextCursor == nil
        let failed = !loading && error != nil && patches.isEmpty
        status.text = loading ? "Loading \(ChangeRequestTerminology.of(kind: detail?.provider).singular) diff..." : failed ? "" : error
            ?? (empty ? (commit == nil ? "This \(ChangeRequestTerminology.of(kind: detail?.provider).singular) has no file changes." : "This commit has no file changes.") : "")
        status.isHidden = status.text.isEmpty
        if !failed || unavailable?.error != error {
            unavailable?.removeFromSuperview()
            unavailable = nil
        }
        if failed, unavailable == nil, let error, let d = detail {
            let v = PullRequestDiffUnavailableView(error: error, provider: d.provider)
            v.onRetry = { [weak self] in self?.onRetry?() }
            v.onOpen = { [weak self] in if let url = self?.detail?.url { self?.onOpenURL?(url) } }
            addSubview(v)
            unavailable = v
        }
        scroll.isHidden = failed
        footer.text = nextCursor == nil ? "" : moreError != nil ? "The rest of this diff could not be loaded." : moreLoading ? "Loading more files..." : ""
        footerRetry.isHidden = nextCursor == nil || moreError == nil
        updateCounts()
        updateAnnotations()
        needsLayout = true
    }

    func setViewed(states: [String: String]?, overlay: [String: Bool], store: String?) {
        guard states != self.states || overlay != self.overlay || store != self.store else { return }
        self.states = states; self.overlay = overlay; self.store = store
        // Marks that load after the diff still fold their files, unless the reader chose (#34168).
        applyFolds()
        if store == nil {
            list.viewedState = nil
        } else {
            list.viewedState = { [weak self] (path: String) -> (viewed: Bool, stale: Bool)? in
                guard let self else { return nil }
                let viewed = PullRequestDetailLogic.isFileViewed(path, states: self.states, overlay: self.overlay)
                let stale = self.overlay[path] == nil && PullRequestDetailLogic.isStale(path, states: self.states)
                return (viewed: viewed, stale: stale)
            }
        }
        updateCounts()
    }

    /// A linked file or line waiting for its patch slice (#33989).
    private var pendingReveal: (digest: String, range: PullRequestAnchor.Range?)?

    /// `useCodeViewFileReveal`: scrolls to the file whose path hashes to `digest`, and to the line
    /// range's start. A file not loaded yet waits for the slice that brings it.
    func reveal(digest: String, range: PullRequestAnchor.Range?) {
        guard let path = paths.first(where: { PullRequestAnchor.pathMatches(digest, $0) }) else { pendingReveal = (digest, range); return }
        pendingReveal = nil
        guard var range else { list.reveal(path: path); return }
        // A GitLab line code whose old line was removed names that old line (resolvePullRequestAnchorRange).
        let removed = Set(list.diff.files.first { $0.path == path }.map { f in f.hunks.flatMap { h in h.lines.compactMap { i -> Int? in
            let l = list.diff.lines[i]; return l.kind == .deletion ? Int(l.oldNumber) : nil } } } ?? [])
        range = PullRequestAnchor.resolve(range) { removed.contains($0) }
        list.reveal(path: path, line: range.start, side: range.side)
    }

    /// The loaded files in file tree order, tests left out while hidden (PullRequestCodeTab.tsx, #26730, #29083).
    private func rebuildDiff() {
        let joined = patches.joined(separator: patches.allSatisfy { $0.hasSuffix("\n") } ? "" : "\n")
        var full = UnifiedDiff(PullRequestDetailLogic.splicingWithheld(joined, loaded: withheldLoaded))
        // A withheld file's header counts come from the host's stats (:1152-1159).
        for i in full.files.indices where full.files[i].hunks.isEmpty && full.files[i].additions == 0 && full.files[i].deletions == 0 {
            if let stat = omitted[full.files[i].path] { full.files[i].additions = stat.additions; full.files[i].deletions = stat.deletions }
        }
        let order = orderDiffPathsLikeTree(full.files.map(\.path))
        let tests = Set(full.files.indices.filter { ChangedFileKind.isTest(full.files[$0].path) })
        testFileCount = tests.count
        let shown = DiffHideTestFiles.value ? order.filter { !tests.contains($0) } : order
        hiddenTestFileCount = order.count - shown.count
        let diff = full.selecting(shown)
        paths = diff.files.map(\.path)
        list.setDiff(diff, collapsedByDefault: false)
        filePane.tree.changes = Dictionary(diff.files.map { ($0.path, $0.change) }, uniquingKeysWith: { a, b in a == b ? a : .change })
        filePane.tree.model = DiffPanelSearch.tree(diff)
        if let pendingReveal { DispatchQueue.main.async { [weak self] in self?.reveal(digest: pendingReveal.digest, range: pendingReveal.range) } }
        hideTestsToggle.isPressed = DiffHideTestFiles.value
        hideTestsToggle.isHidden = testFileCount == 0
        hideTestsTooltip?.text = DiffHideTestFiles.value ? "Show test files" : "Hide test files"
    }

    /// The host's withheld files and what has been read of them. `loaded` holds each read file's patch.
    func setWithheld(omitted: [String: (additions: Int, deletions: Int)], readable: Bool, loaded: [String: String],
                     status: [String: PullRequestWithheldFileNotice.Status]) {
        let patchesChanged = loaded != withheldLoaded || omitted.keys.sorted() != self.omitted.keys.sorted()
        self.omitted = omitted; withheldReadable = readable; withheldStatus = status
        withheldLoaded = loaded
        for (path, notice) in withheldNotices { notice.update(status[path] ?? .idle) }
        if patchesChanged {
            rebuildDiff()
            applyFolds()
            updateCounts()
        }
        updateAnnotations()
    }

    private func setHideTests(_ hide: Bool) {
        guard hide != DiffHideTestFiles.value else { return }
        DiffHideTestFiles.value = hide
        rebuildDiff()
        applyFolds()
        updateCounts()
        updateAnnotations()
    }

    /// `diffFilesCollapsed` on folds every file; off leaves it to the Viewed marks (PullRequestCodeTab.tsx:458).
    private var defaultFold: Bool? { ClientSettingsStore.shared.current.bool("diffFilesCollapsed") ? true : nil }

    private func foldsAsViewed(_ path: String) -> Bool {
        store != nil && PullRequestDetailLogic.isFileViewed(path, states: states, overlay: overlay)
            && !(overlay[path] == nil && PullRequestDetailLogic.isStale(path, states: states))
    }

    private func applyFolds() {
        let folded = defaultFold
        list.setCollapsedFiles(Set(paths.indices.filter {
            PullRequestDetailLogic.isFileDiffCollapsed(paths[$0], folded: folded, choices: foldChoices, viewed: foldsAsViewed(paths[$0]))
        }))
    }

    /// The conversations and the review being written (PullRequestCodeTab.tsx:478-560).
    func setReview(_ d: PullRequestDetail, reviewKey: String, actions: PullRequestReviewThreadActions, nowMs: Int64) {
        if detail?.url != d.url { threadCards = [:]; draft = nil; shownThreads = []; resolvedButtons = [:] }
        detail = d
        self.reviewKey = reviewKey
        self.actions = actions
        self.nowMs = nowMs
        for t in d.reviewThreads { threadCards[t.id]?.update(t) }
        let offer = PullRequestWriteLogic.composerOffer(d)
        if d.capabilities.review.inlineComment && !offer.verdicts.isEmpty {
            list.onLineClick = { [weak self] target in self?.startDraft(target) }
        } else {
            list.onLineClick = nil
        }
        updateAnnotations()
    }

    private func startDraft(_ target: DiffLineTarget) {
        guard commit == nil else { return }
        let line = target.right ? target.newLine : target.oldLine
        let view = PullRequestDraftCommentView(rangeLabel: "\(target.path):\(line)")
        view.onCancel = { [weak self] in self?.draft = nil; self?.updateAnnotations() }
        view.onComment = { [weak self] body in self?.addPending(target, body) }
        view.onResize = { [weak self] in self?.list.reloadAnnotations() }
        draft = (target, view)
        updateAnnotations()
        DispatchQueue.main.async { [weak view] in view?.focus() }
    }

    /// "Add to review": the draft becomes a pending comment (lines 1040-1052).
    private func addPending(_ t: DiffLineTarget, _ body: String) {
        guard let reviewKey else { return }
        let position: PullRequestReviewPosition = switch t.kind {
        case .addition: .added(newLine: t.newLine)
        case .deletion: .deleted(oldLine: t.oldLine)
        case .context: .context(oldLine: t.oldLine, newLine: t.newLine, side: t.right ? "right" : "left")
        }
        let store = PullRequestReviewStore.shared
        draft = nil
        store.add(reviewKey, PullRequestReviewCommentDraft(id: store.nextId(), path: t.path, oldPath: t.oldPath == t.path ? nil : t.oldPath,
                                                           position: position, body: body))
    }

    private func updateAnnotations() {
        var annotations: [DiffAnnotation] = []
        // A commit's diff counts lines within that commit; review comments anchor to the head diff.
        if let d = detail, commit == nil {
            // `InlineReviewThreads`: a line's resolved conversations fold behind their authors' avatars.
            let lined = d.reviewThreads.filter { $0.line != nil }
            for t in lined where !t.isResolved { shownThreads.insert(t.id) }
            var groups: [String: [PullRequestReviewThread]] = [:]
            var order: [String] = []
            for t in lined {
                let key = PullRequestDetailLogic.threadLineKey(t)
                if groups[key] == nil { order.append(key) }
                groups[key, default: []].append(t)
            }
            for key in order {
                let threads = groups[key]!
                let resolved = threads.filter(\.isResolved)
                if !resolved.isEmpty, let first = threads.first, let line = first.line {
                    annotations.append(DiffAnnotation(path: first.path, right: first.side == "right", line: line,
                                                      id: "resolved:\(key):\(resolved.map(\.id).joined(separator: ","))"))
                }
                for t in threads where !t.isResolved || shownThreads.contains(t.id) {
                    annotations.append(DiffAnnotation(path: t.path, right: t.side == "right", line: t.line!, id: "thread:\(t.id)"))
                }
            }
            for c in reviewKey.map(PullRequestReviewStore.shared.comments) ?? [] {
                let a = c.position.anchor
                annotations.append(DiffAnnotation(path: c.path, right: a.side == "right", line: a.line, id: "pending:\(c.id):\(c.body.hashValue)"))
            }
            if let draft {
                let t = draft.target
                annotations.append(DiffAnnotation(path: t.path, right: t.right, line: t.right ? t.newLine : t.oldLine, id: "draft"))
            }
        }
        // A withheld file's notice sits under its header (`lineNumber: 0`, :867-878).
        for f in list.diff.files where f.hunks.isEmpty && omitted[f.path] != nil {
            annotations.append(DiffAnnotation(path: f.path, right: true, line: 0, id: "withheld:\(f.path)"))
        }
        for b in resolvedButtons.values { b.expanded = b.threadIds.allSatisfy(shownThreads.contains) }
        list.annotations = annotations
        list.reloadAnnotations()
        rebuildOrphans()
    }

    /// Add to chat on a line's conversation; nil where no composer sits beside the panel.
    var onAddToChat: ((PullRequestReviewThread) -> Void)? {
        didSet { threadCards.values.forEach { $0.onAddToChat = onAddToChat } }
    }

    private func threadCard(_ t: PullRequestReviewThread) -> PullRequestReviewThreadCardView? {
        guard let d = detail, let actions else { return nil }
        if let card = threadCards[t.id] { return card }
        let card = PullRequestReviewThreadCardView(
            thread: t, canReply: d.capabilities.review.reply, canResolve: d.capabilities.review.resolve && PullRequestWriteLogic.canResolveThread(d, t),
            canReact: d.capabilities.reactions == true,
            canEdit: { c in PullRequestWriteLogic.canEditComment(d, author: c.author?.login, kind: "review-comment", hostAnswer: c.canEdit) },
            actions: actions, cwd: d.workspaceRoot, nowMs: nowMs, startsExpanded: t.line != nil ? true : nil,
            lineBreaks: PullRequestDetailLogic.hardLineBreaks(d.provider))
        card.onResize = { [weak self] in self?.list.reloadAnnotations(); self?.needsLayout = true }
        if let onAddToChat { card.onAddToChat = { onAddToChat($0) } }
        threadCards[t.id] = card
        return card
    }

    private func annotationView(_ a: DiffAnnotation) -> DiffAnnotationContent? {
        if a.id == "draft" { return draft?.view }
        if a.id.hasPrefix("resolved:"), let d = detail {
            let key = String(a.id.dropFirst("resolved:".count)).components(separatedBy: ":").dropLast().joined(separator: ":")
            let threads = d.reviewThreads.filter { $0.line != nil && PullRequestDetailLogic.threadLineKey($0) == key }
            let resolved = threads.filter(\.isResolved)
            let expanded = resolved.allSatisfy { shownThreads.contains($0.id) }
            if let b = resolvedButtons[a.id] { b.expanded = expanded; return b }
            let b = PullRequestResolvedThreadsButton(threads: resolved, expanded: expanded)
            b.onToggle = { [weak self] in
                guard let self else { return }
                if resolved.allSatisfy({ self.shownThreads.contains($0.id) }) {
                    self.shownThreads.subtract(resolved.map(\.id))
                } else {
                    self.shownThreads.formUnion(threads.map(\.id))
                }
                self.updateAnnotations()
            }
            resolvedButtons[a.id] = b
            return b
        }
        if a.id.hasPrefix("withheld:") {
            let path = String(a.id.dropFirst("withheld:".count))
            if let notice = withheldNotices[path] { return notice }
            let notice = PullRequestWithheldFileNotice(path: path, status: withheldStatus[path] ?? .idle,
                                                       onLoad: withheldReadable ? { [weak self] p in self?.onLoadWithheld?(p) } : nil)
            withheldNotices[path] = notice
            return notice
        }
        if a.id.hasPrefix("thread:"), let t = detail?.reviewThreads.first(where: { "thread:\($0.id)" == a.id }) { return threadCard(t) }
        if a.id.hasPrefix("pending:"), let key = reviewKey,
           let c = PullRequestReviewStore.shared.comments(key).first(where: { a.id.hasPrefix("pending:\($0.id):") }) {
            let card = PullRequestPendingCommentCardView(c)
            card.onRemove = { PullRequestReviewStore.shared.remove(key, ids: [c.id]) }
            return card
        }
        return nil
    }

    /// Conversations whose line is not in a rendered hunk (lines 1434-1500): above the code, folded.
    private func rebuildOrphans() {
        orphanCards.forEach { $0.removeFromSuperview() }
        guard let d = detail else { orphanCards = []; return }
        let placed = list.placedAnnotationIds
        // A folded resolved conversation is on its line, behind the avatars.
        let foldedLines = Set(placed.filter { $0.hasPrefix("resolved:") }.map { $0.dropFirst("resolved:".count).components(separatedBy: ":").dropLast().joined(separator: ":") })
        let orphans = d.reviewThreads.filter { t in
            !placed.contains("thread:\(t.id)") && !(t.isResolved && t.line != nil && foldedLines.contains(PullRequestDetailLogic.threadLineKey(t)))
        }
        orphanCards = orphans.compactMap { t in
            // A card shows in one place: the list takes it while its line is not drawn.
            guard let card = threadCard(t) else { return nil }
            card.removeFromSuperview()
            orphanDocument.addSubview(card)
            return card
        }
        let n = orphans.count
        orphanToggle.text = (nextCursor == nil ? "Conversations not on the current diff" : "Conversations not on the diff loaded so far") + "   \(n)"
        orphanToggle.setAccessibilityLabel(n == 1 ? "1 conversation" : "\(n) conversations")
        needsLayout = true
    }

    private func updateCounts() {
        let files = "\(paths.count) \(paths.count == 1 ? "file" : "files")" + (nextCursor == nil ? "" : "+")
        var viewed = ""
        if store != nil && !paths.isEmpty {
            viewed = "  ·  \(PullRequestDetailLogic.countViewed(paths, states: states, overlay: overlay)) / \(paths.count) "
            viewed += store == "environment" ? "viewed in T3 Code" : "viewed"
        }
        hiddenTestsLink.isHidden = hiddenTestFileCount == 0
        hiddenTestsLink.text = "\(hiddenTestFileCount) test \(hiddenTestFileCount == 1 ? "file" : "files") hidden"
        // Without hidden tests the line stays one label, as before.
        counts.text = hiddenTestsLink.isHidden ? files + viewed : files + "  ·  "
        viewedCounts.text = hiddenTestsLink.isHidden || viewed.isEmpty ? "" : "·  " + viewed.dropFirst(5)
        viewedCounts.isHidden = viewedCounts.text.isEmpty
        needsLayout = true
    }

    private func showScopeMenu() {
        var items = [MenuItem.radio("All commits", checked: commit == nil) { [weak self] _ in self?.onCommit?(nil) }]
        items[0].closesOnClick = true
        for c in commits.prefix(50) {
            var item = MenuItem.radio(c.messageHeadline, checked: commit == c.oid) { [weak self] _ in self?.onCommit?(c.oid) }
            item.shortcut = String(c.oid.prefix(7))
            item.closesOnClick = true
            items.append(item)
        }
        MenuPopupView.show(items, from: scope, placement: .dropdown)
    }

    public override func layout() {
        super.layout()
        let w = bounds.width
        CATransaction.begin(); CATransaction.setDisableActions(true)
        toolbarFill.frame = CGRect(x: 0, y: 0, width: w, height: 40)
        rule.frame = CGRect(x: 0, y: 40, width: w, height: 1)
        CATransaction.commit()
        var x: CGFloat = 16
        if !scope.isHidden {
            let sw = min(256, ceil(scope.intrinsicContentSize.width))
            scope.frame = NSRect(x: x, y: 8, width: sw, height: 24); x += sw + 12
        }
        var right = w - 16
        // `fileKeys.length > 0`: the toggle sits last, after Hide test files.
        treeToggle.isHidden = paths.isEmpty
        if !treeToggle.isHidden {
            treeToggle.frame = NSRect(x: right - 28, y: 6, width: 28, height: 28); right -= 28 + 8
        }
        if !hideTestsToggle.isHidden {
            hideTestsToggle.frame = NSRect(x: right - 28, y: 6, width: 28, height: 28); right -= 28 + 8
        }
        if hiddenTestsLink.isHidden {
            counts.frame = NSRect(x: x, y: 12, width: max(0, right - x), height: 16)
        } else {
            let cw = ceil(counts.textWidth), lw = ceil(hiddenTestsLink.textWidth) + 1
            counts.frame = NSRect(x: x, y: 12, width: min(cw, max(0, right - x)), height: 16)
            hiddenTestsLink.frame = NSRect(x: x + cw, y: 12, width: min(lw, max(0, right - x - cw)), height: 16)
            let vx = x + cw + lw + 6
            viewedCounts.frame = NSRect(x: vx, y: 12, width: max(0, right - vx), height: 16)
        }
        var top: CGFloat = 41
        let hasOrphans = !orphanCards.isEmpty
        [orphanToggle, orphanChevron].forEach { $0.isHidden = !hasOrphans }
        orphanScroll.isHidden = !hasOrphans || !orphansOpen
        orphanRule.isHidden = !hasOrphans
        if hasOrphans {
            let tw = ceil(orphanToggle.textWidth) + 1
            orphanToggle.frame = NSRect(x: 16, y: top + 8, width: tw, height: 16)
            orphanChevron.frame = NSRect(x: 16 + tw + 6, y: top + 9, width: 14, height: 14)
            top += 32
            if orphansOpen {
                var y: CGFloat = 0
                for card in orphanCards {
                    let h = card.height(forWidth: w)
                    card.frame = NSRect(x: 0, y: y, width: w, height: h)
                    y += h
                }
                let h = min(y, max(0, (bounds.height - top) / 2))
                orphanScroll.frame = NSRect(x: 0, y: top, width: w, height: h)
                orphanDocument.frame = NSRect(x: 0, y: 0, width: w, height: y)
                top += h
            }
            orphanRule.frame = CGRect(x: 0, y: top, width: w, height: 1)
            top += 1
        }
        let footerH: CGFloat = footer.text.isEmpty ? 0 : 32
        filePane.isHidden = !treeToggle.isPressed || treeToggle.isHidden
        // Load more files under the tree (`border-t p-2`, outline, full width), Retry after a failure.
        loadMoreFiles.title = moreError != nil ? "Retry" : moreLoading ? "Loading more files..." : "Load more files"
        loadMoreFiles.isEnabled = !moreLoading
        if (filePane.footer == nil) != (nextCursor == nil) { filePane.footer = nextCursor == nil ? nil : loadMoreFiles }
        let paneW = filePane.isHidden ? 0 : filePane.place(in: NSRect(x: 0, y: top, width: w, height: max(0, bounds.height - top)), host: self)
        scroll.frame = NSRect(x: 0, y: top, width: w - paneW, height: max(0, bounds.height - top - footerH))
        status.frame = NSRect(x: 16, y: top + 24, width: max(0, w - 32), height: 16)
        unavailable?.frame = NSRect(x: 0, y: top, width: w, height: max(0, bounds.height - top))
        footer.isHidden = footerH == 0
        let rw = footerRetry.isHidden ? 0 : ceil(footerRetry.intrinsicContentSize.width) + 8
        let fw = ceil(footer.textWidth) + 1
        let fx = (w - fw - rw) / 2
        footer.frame = NSRect(x: fx, y: bounds.height - footerH + 8, width: fw, height: 16)
        footerRetry.frame = NSRect(x: fx + fw + 8, y: bounds.height - footerH + 4, width: rw - 8, height: 24)
    }

    public override func updateLayer() {
        toolbarFill.backgroundColor = WindowGlass.paneFill.cgColor(in: self)
        rule.backgroundColor = Themed.color(\.border, 0.6).cgColor(in: self)
        orphanRule.backgroundColor = Themed.color(\.border, 0.6).cgColor(in: self)
        counts.color = Themed.color(\.mutedForeground)
        viewedCounts.color = Themed.color(\.mutedForeground)
        status.color = Themed.color(\.mutedForeground)
        footer.color = Themed.color(\.mutedForeground)
        orphanToggle.color = Themed.color(\.mutedForeground)
        hiddenTestsLink.color = Themed.color(\.primary)
        orphanChevron.strokeColor = Themed.color(\.mutedForeground)
    }
}
