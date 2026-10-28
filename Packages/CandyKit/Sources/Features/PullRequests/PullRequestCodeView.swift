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
    private var orphanCards: [PullRequestReviewThreadCardView] = []
    private var reviewObserver: NSObjectProtocol?
    isolated deinit { if let reviewObserver { NotificationCenter.default.removeObserver(reviewObserver) } }
    var onCommit: ((String?) -> Void)?
    var onSetViewed: (([String], Bool) -> Void)?
    /// The file last marked viewed or not, where a shift-click's range starts. A new scope forgets it.
    private var viewedAnchor: String?
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
        [scope, counts, scroll, status, footer, footerRetry, orphanToggle, orphanChevron, orphanScroll].forEach(addSubview)
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
            // The list folds the clicked file itself; the rest of the range folds the same way.
            for other in range where other != path { if let i = self.paths.firstIndex(of: other) { self.list.setCollapsed(i, viewed) } }
            self.onSetViewed?(range.isEmpty ? [path] : range, viewed)
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
        commit = nil; paths = []; patches = []; nextCursor = nil; draft = nil; threadCards = [:]; viewedAnchor = nil
        list.annotations = []
        list.setDiff(UnifiedDiff(""))
    }

    /// The slices read so far, in order; `nextCursor` says more is owed.
    func set(patches: [String], loading: Bool, error: String?, nextCursor: String?, moreLoading: Bool, moreError: String?,
             commit: String?, commits: [PullRequestCommit]) {
        self.commits = commits.sorted { (T3Timestamp($0.committedDate).epochMs ?? 0) > (T3Timestamp($1.committedDate).epochMs ?? 0) }
        if commit != self.commit { draft = nil; viewedAnchor = nil }
        self.commit = commit
        self.nextCursor = nextCursor
        self.moreLoading = moreLoading
        self.moreError = moreError
        scope.title = commit.flatMap { oid in commits.first { $0.oid == oid }?.messageHeadline } ?? "All commits"
        scope.isHidden = commits.isEmpty
        if patches != self.patches {
            let grew = !self.patches.isEmpty && patches.count > self.patches.count && Array(patches.prefix(self.patches.count)) == self.patches
            let wasCollapsed = list.collapsed
            self.patches = patches
            let diff = UnifiedDiff(patches.joined(separator: patches.allSatisfy { $0.hasSuffix("\n") } ? "" : "\n"))
            let oldCount = paths.count
            paths = diff.files.map(\.path)
            list.setDiff(diff, collapsedByDefault: false)
            if grew {
                // An appended slice keeps what the reader already folded.
                for f in wasCollapsed where f < oldCount { list.setCollapsed(f, true) }
                for (i, p) in paths.enumerated() where i >= oldCount && PullRequestDetailLogic.isFileViewed(p, states: states, overlay: overlay) { list.setCollapsed(i, true) }
            } else {
                // Viewed files start folded.
                for (i, p) in paths.enumerated() where PullRequestDetailLogic.isFileViewed(p, states: states, overlay: overlay) { list.setCollapsed(i, true) }
            }
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

    /// The conversations and the review being written (PullRequestCodeTab.tsx:478-560).
    func setReview(_ d: PullRequestDetail, reviewKey: String, actions: PullRequestReviewThreadActions, nowMs: Int64) {
        if detail?.url != d.url { threadCards = [:]; draft = nil }
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
            for t in d.reviewThreads { if let line = t.line { annotations.append(DiffAnnotation(path: t.path, right: t.side == "right", line: line, id: "thread:\(t.id)")) } }
            for c in reviewKey.map(PullRequestReviewStore.shared.comments) ?? [] {
                let a = c.position.anchor
                annotations.append(DiffAnnotation(path: c.path, right: a.side == "right", line: a.line, id: "pending:\(c.id):\(c.body.hashValue)"))
            }
            if let draft {
                let t = draft.target
                annotations.append(DiffAnnotation(path: t.path, right: t.right, line: t.right ? t.newLine : t.oldLine, id: "draft"))
            }
        }
        list.annotations = annotations
        list.reloadAnnotations()
        rebuildOrphans()
    }

    private func threadCard(_ t: PullRequestReviewThread) -> PullRequestReviewThreadCardView? {
        guard let d = detail, let actions else { return nil }
        if let card = threadCards[t.id] { return card }
        let card = PullRequestReviewThreadCardView(
            thread: t, canReply: d.capabilities.review.reply, canResolve: d.capabilities.review.resolve && PullRequestWriteLogic.canResolveThread(d, t),
            canReact: d.capabilities.reactions == true,
            canEdit: { c in PullRequestWriteLogic.canEditComment(d, author: c.author?.login, kind: "review-comment", hostAnswer: c.canEdit) },
            actions: actions, cwd: d.workspaceRoot, nowMs: nowMs)
        card.onResize = { [weak self] in self?.list.reloadAnnotations(); self?.needsLayout = true }
        threadCards[t.id] = card
        return card
    }

    private func annotationView(_ a: DiffAnnotation) -> DiffAnnotationContent? {
        if a.id == "draft" { return draft?.view }
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
        let orphans = d.reviewThreads.filter { !placed.contains("thread:\($0.id)") }
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
        var text = "\(paths.count) \(paths.count == 1 ? "file" : "files")" + (nextCursor == nil ? "" : "+")
        if store != nil && !paths.isEmpty {
            text += "  ·  \(PullRequestDetailLogic.countViewed(paths, states: states, overlay: overlay)) / \(paths.count) "
            text += store == "environment" ? "viewed in T3 Code" : "viewed"
        }
        counts.text = text
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
        counts.frame = NSRect(x: x, y: 12, width: max(0, w - 16 - x), height: 16)
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
        scroll.frame = NSRect(x: 0, y: top, width: w, height: max(0, bounds.height - top - footerH))
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
        status.color = Themed.color(\.mutedForeground)
        footer.color = Themed.color(\.mutedForeground)
        orphanToggle.color = Themed.color(\.mutedForeground)
        orphanChevron.strokeColor = Themed.color(\.mutedForeground)
    }
}
