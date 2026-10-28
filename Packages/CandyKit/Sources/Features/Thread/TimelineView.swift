import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// Which rows of the timeline an update touched.
enum TimelineChange: Equatable, Sendable {
    /// Anything may have changed.
    case all
    /// Only these rows changed; the count and the ids stayed.
    case rows([Int])
    /// Rows before this index stayed; the ones from it on are new.
    case tail(Int)
    /// The first `replaced` rows gave way to `inserted` new ones; every row after them stayed
    /// (an older history page).
    case head(replaced: Int, inserted: Int)
    /// Another thread's rows replace the last thread's in one pass; the view starts at the end.
    case thread
}

/// The messages timeline (MessagesTimeline.tsx): a virtualized list in T3's centered chat lane.
///
/// Only rows inside the visible rect plus `overscan` have views, recycled per kind. Each row's
/// measured height is cached by id, width and content; rows never measured use an estimate. When
/// heights or rows above the viewport change, the first visible row keeps its place on screen.
/// While the viewport touches the end, it follows the end as content grows (`maintainScrollAtEnd`).
public final class TimelineView: DSView, @preconcurrency NSAccessibilityCustomRotorItemSearchDelegate, @preconcurrency NSAccessibilityElementLoading {
    /// Paint only: while another thread opens, the rows still on screen belong to the old thread and take
    /// no clicks, scrolls or hovers (T3 renders them inert, ChatView.tsx:3964-3974).
    public var isInert = false
    public override func hitTest(_ point: NSPoint) -> NSView? { isInert ? nil : super.hitTest(point) }
    static let overscan: CGFloat = 400
    /// `--chat-content-max-width` at the default `comfortable` chat width.
    static let maxLane: CGFloat = 736
    /// The list footer under the last row (`h-3 sm:h-4`).
    static let footer: CGFloat = 16
    /// Distance from the top that asks for older history.
    static let nearTop: CGFloat = 600

    enum Kind: Hashable { case approval, user, workflowOpening, assistant, meta, plan, work, toggle, live, thinking, working, turnFold, attemptFold, compaction, event, subagent, secret, linkRequest, htmlRender, mcpApp }

    let context = TimelineContext()
    let scrollView = ComposerTimelineScrollView()
    public var overflowsComposerViewport: Bool { (scrollView.documentView?.bounds.height ?? 0) > scrollView.contentView.bounds.height + 1 }
    public var onComposerScrollGesture: ((CGFloat, Bool, Bool) -> Void)?
    private let document = DSView()
    private let minimap = ThreadMinimapView()
    public let worktreeSetup = ThreadWorktreeSetupView()
    private var setupHeight: CGFloat = 0
    private let pill = ButtonView("Scroll to end", icon: .chevronDown, variant: .glass, size: .xs)

    private(set) var items: [TimelineItem] = []
    private var heights: [CGFloat] = []
    private var tops: [CGFloat] = []
    private var indexById: [String: Int] = [:]
    private var measured: [String: (width: CGFloat, item: TimelineItem, height: CGFloat)] = [:]
    private var visible: [String: TimelineRowView] = [:]
    private var pools: [Kind: [TimelineRowView]] = [:]
    private var clipObserver: NSObjectProtocol?
    private var adjusting = false
    private var pillWork: DispatchWorkItem?
    private var lastNearTopId: String?
    /// A bounded page can prepend tools within the same folded row. Rearm demand when
    /// its cursor advances, even when the first rendered row keeps the same identity.
    public var historyCursor: String? {
        didSet { if historyCursor != oldValue { lastNearTopId = nil } }
    }
    /// A request that ends without a page, cancelled or failed, keeps the same cursor. Rearm then, so the
    /// next upward gesture retries it; T3 keeps Load earlier usable after an error (MessagesTimeline.tsx:1144-1169,
    /// audit TH-1).
    public var historyLoading = false {
        didSet { if oldValue && !historyLoading { lastNearTopId = nil } }
    }
    public var historyFailed = false {
        didSet { if historyFailed { lastNearTopId = nil } }
    }
    private var laidOutWidth: CGFloat = 0
    private var tiling = false
    private var retile = false
    public var threadFindMatch: ThreadFindResult.Match? { didSet { if threadFindMatch != oldValue { visible.values.forEach(applyFindHighlight) } } }
    public var threadFindQuery = "" {
        didSet { if threadFindQuery != oldValue { visible.values.forEach(applyFindHighlight) } }
    }
    /// T3 searches and paints only message and plan text (ThreadFind.ts `searchableRows`, MessagesTimeline.tsx:2753, 4737,
    /// ProposedPlanCard.tsx:170-198), never tool output.
    private func applyFindHighlight(_ view: TimelineRowView) {
        guard let item = view.item else { return }
        let searchable: Bool = if case .proposedPlan = item.row.kind { true } else { item.row.message != nil }
        view.applyThreadFind(query: searchable ? threadFindQuery : "",
                             occurrence: searchable && item.id == threadFindMatch?.entryId ? threadFindMatch?.occurrence : nil)
    }

    /// Scrolls the least that brings the active match inside the viewport, 96pt from its edges and clear of the
    /// composer (`reveal`, useThreadFindNavigation.ts:185-230). False when its row is not on screen.
    /// A find match in a long answer still parsing or laying out in the background, revealed once it lands.
    private var pendingFindReveal: String?

    private func revealPendingFindMatch() {
        guard let id = pendingFindReveal else { return }
        guard threadFindMatch?.entryId == id else { pendingFindReveal = nil; return }
        _ = revealActiveFindMatch(id, retry: false)
    }

    private func revealActiveFindMatch(_ entryId: String, retry: Bool = true) -> Bool {
        guard threadFindMatch?.entryId == entryId, let row = visible[entryId] else { return false }
        row.layoutSubtreeIfNeeded()
        guard let local = row.activeFindRect() else {
            // A fold opened: ask again once the row has its new height. A long answer laying out in the background
            // asks again when it lands.
            if retry { DispatchQueue.main.async { [weak self] in _ = self?.revealActiveFindMatch(entryId, retry: false) } }
            else { pendingFindReveal = entryId }
            return true
        }
        pendingFindReveal = nil
        let rect = row.convert(local, to: document)
        let viewport = scrollView.contentView.bounds
        let margin = min(96, max(0, (viewport.height - topClearance - bottomInset - rect.height) / 2))
        let top = viewport.minY + topClearance + margin, bottom = viewport.maxY - margin - bottomInset
        let delta = rect.minY < top ? rect.minY - top : rect.maxY > bottom ? rect.maxY - bottom : 0
        if abs(delta) >= 1 {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, min(maxScroll, viewport.minY + delta))))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            tile()
        }
        return true
    }


    /// Space above the first row: the `topbar-scroll-fade` spacer (1.5rem), under the header view if any.
    public var topInset: CGFloat = 24 { didSet { if topInset != oldValue { relayout() } } }
    /// The top of the timeline the thread header covers. Glass scrolls rows on under the header, so the
    /// timeline starts at the panel's top and the rows, scroller and minimap keep clear of this much.
    public var topClearance: CGFloat = 0 {
        didSet {
            guard topClearance != oldValue else { return }
            scrollView.scrollerInsets.top = topClearance
            updateTopInset()
            layoutHeader()
            layoutMinimap()
        }
    }
    /// A view above the rows in the lane (the list header's "Subagent of" divider, MessagesTimeline.tsx:1409-1437),
    /// `headerHeight` tall, before the 24pt spacer.
    public func setHeader(_ view: NSView?, height: CGFloat) {
        if header !== view {
            header?.removeFromSuperview()
            header = view
            if let view { document.addSubview(view) }
        }
        headerHeight = view == nil ? 0 : height
        updateTopInset()
        layoutHeader()
    }
    private var header: NSView?
    private var headerHeight: CGFloat = 0
    /// A view after the last row (the list footer: `ThreadStatusLine`, ChatView.tsx:7613-7646, 11410). A
    /// `TimelineSizedFooter` is measured again when the lane's width changes.
    public func setFooter(_ view: NSView?, height: CGFloat) {
        if footerView !== view {
            footerView?.removeFromSuperview()
            footerView = view
            if let view { document.addSubview(view) }
        }
        let h = view == nil ? 0 : height
        layoutEmptyPlaceholder()
        guard h != footerHeight else { return }
        footerHeight = h
        let anchor = captureAnchor()
        recomputeTops()
        restore(anchor)
        tile()
    }
    private var footerView: NSView?
    private var footerHeight: CGFloat = 0
    private func layoutHeader() {
        let lane = laneFrame
        let host = worktreeSetup.isHidden ? parked : document
        if worktreeSetup.superview !== host { host.addSubview(worktreeSetup) }
        header?.frame = NSRect(x: TL.snap(lane.x), y: topClearance, width: lane.width, height: headerHeight)
        let height = worktreeSetup.height(forWidth: lane.width)
        worktreeSetup.frame = NSRect(x: TL.snap(lane.x), y: topClearance + headerHeight + 12, width: lane.width, height: height)
        if setupHeight != height { setupHeight = height; updateTopInset() }
        layoutEmptyPlaceholder()
    }

    private func updateTopInset() { topInset = 24 + topClearance + headerHeight + setupHeight }

    /// Space the floating composer covers at the bottom. The last row scrolls clear of it.
    public var bottomInset: CGFloat = 0 { didSet { if bottomInset != oldValue { relayout(); layoutEmptyPlaceholder(); needsLayout = true } } }

    /// A loaded server thread (T3's `hideEmptyPlaceholder` is false): with nothing to list, the timeline
    /// says so (MessagesTimeline.tsx:1541-1562). Drafts and loading threads leave it off.
    public var allowsEmptyPlaceholder = false { didSet { if allowsEmptyPlaceholder != oldValue { layoutEmptyPlaceholder() } } }
    /// Built the first time it shows.
    private var emptyLabel: LabelView?
    /// No rows, no "Subagent of" link, no setup card and no status line under the list.
    private var showsEmptyPlaceholder: Bool {
        allowsEmptyPlaceholder && items.isEmpty && header == nil && footerView == nil && worktreeSetup.isHidden
    }
    /// `flex h-full items-center justify-center`, `text-sm text-muted-foreground/30`.
    private func layoutEmptyPlaceholder() {
        guard showsEmptyPlaceholder else { emptyLabel?.isHidden = true; return }
        let label = emptyLabel ?? {
            let l = LabelView("Send a message to start the conversation.", font: DSFont.ui(14), color: Themed.color(\.mutedForeground, 0.3))
            l.lineHeight = 20
            addSubview(l)
            emptyLabel = l
            return l
        }()
        label.isHidden = false
        // Centered in the chat lane above the composer (`paddingBottom: contentInsetEndAdjustment` and the lane insets,
        // MessagesTimeline.tsx:1615-1618, T3 3105 aaf83eedd).
        let lane = laneFrame
        let w = min(ceil(label.textWidth) + 1, lane.width)
        let h = max(20, bounds.height - bottomInset - topClearance)
        label.frame = NSRect(x: ((lane.x + (lane.width - w) / 2) * 2).rounded() / 2, y: topClearance + ((h - 20) / 2 * 2).rounded() / 2, width: w, height: 20)
    }
    /// True while the viewport is at the end; new content then keeps it there.
    public private(set) var followsEnd = true
    /// The row whose disclosure just toggled. Until the rows update, it keeps its place on screen instead of
    /// the end staying pinned, so an expanded group opens downward (`suspendEndScrollMaintenanceForDisclosure`,
    /// MessagesTimeline.tsx:719-752).
    private var disclosureRowId: String?
    /// The user scrolled within `nearTop` of the first row. Called once per first row or
    /// history cursor; the visible rows keep their anchor while older items arrive.
    public var onNearTop: (@MainActor () -> Void)?

    /// Recycled rows and the hidden setup card wait here, outside the scroll document. A document
    /// resize (each line a streaming answer adds) invalidates the visible rect of its whole subtree,
    /// and AppKit then displays every drawing layer in it again, hidden ones included: pooled rows
    /// were 60 of the 75 layer displays per streamed token.
    private let parked = NSView()

    /// Counters for tests.
    private(set) var createdRowViews = 0
    private(set) var configureCount = 0

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        minimap.threadTitle = { [weak self] key in self?.context.model?.linkedThread?(ThreadId(key))?.title }
        context.onMarkdownHeightChange = { [weak self] id in
            self?.remeasure { $0.id == id }
            self?.revealPendingFindMatch()
        }
        context.onDocumentReady = { [weak self] key in
            self?.remeasure { $0.id == key }
            self?.revealPendingFindMatch()
        }
        context.onDisclosure = { [weak self] id in
            self?.disclosureRowId = id
            // A toggle that changes no rows must not hold the next, unrelated update.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.disclosureRowId = nil } }
        }
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        // LegendList is a plain overflow scroller with `scrollbar-gutter-both` (MessagesTimeline.tsx:1620): the bar
        // stays drawn while the thread overflows, in the right padding the rows already keep clear.
        scrollView.useT3Scrollbars(.native, reservesLane: false)
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.verticalScrollElasticity = .allowed
        scrollView.documentView = document
        setAccessibilityRole(.group)
        setAccessibilityLabel("Messages")
        let headings = NSAccessibilityCustomRotor(rotorType: .heading, itemSearchDelegate: self)
        headings.itemLoadingDelegate = self
        setAccessibilityCustomRotors([headings])
        scrollView.onGesture = { [weak self] delta, canScroll, towardEnd in
            self?.onComposerScrollGesture?(delta, canScroll, towardEnd)
            // An upward wheel still asks for history when a small folded window fits.
            if delta < 0 { self?.requestEarlierIfNearTop() }
        }
        parked.isHidden = true
        addSubview(parked)
        parked.addSubview(worktreeSetup)
        worktreeSetup.isHidden = true
        worktreeSetup.onHeightChange = { [weak self] in self?.layoutHeader() }
        addSubview(scrollView)
        addSubview(minimap)
        minimap.onSelect = { [weak self] id in self?.revealFindEntry(id) }
        minimap.onWheel = { [weak self] event in self?.scrollView.scrollWheel(with: event) }
        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        clipObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didScroll() }
        }
        pill.isHidden = true
        pill.setAccessibilityLabel("Scroll to end")
        pill.action = { [weak self] in self?.scrollToEnd(animated: true) }
        addSubview(pill)
        // A new time format redraws the timestamps of the rows on screen (T3 re-renders them).
        ClientSettingsStore.shared.observe { [weak self] keys in
            if keys.contains("timestampFormat") { self?.reconfigureVisible() }
            if keys.contains("chatWidth"), let self { self.laidOutWidth = -1; self.needsLayout = true }
            // Code blocks start wrapped or not by `wordWrap` (MarkdownView reads it as T3 does at mount), which changes
            // their heights: every row measures again.
            // "Render math" changes how messages parse: drop the parses first, then measure like `wordWrap`.
            if keys.contains("mathRenderingEnabled") { self?.context.forgetDocuments() }
            if keys.contains("wordWrap") || keys.contains("mathRenderingEnabled"), let self {
                self.measured.removeAll()
                self.reconfigureVisible()
                self.heights = self.items.map { self.height(of: $0) }
                self.relayout()
            }
        }
        // A Mermaid diagram finished or toggled: the messages with diagrams measure again (their Markdown views
        // drop their own layouts first, so this waits a turn of the run loop).
        diagramObserver = NotificationCenter.default.addObserver(forName: MermaidDiagrams.didRender, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.remeasure(containing: "mermaid") } }
        }
        // An image decoded and takes its own size instead of the loading slot: the same for messages with images.
        // A tool output image measures the open work row that shows it.
        imageObserver = NotificationCenter.default.addObserver(forName: MarkdownImages.didMeasure, object: nil, queue: .main) { [weak self] note in
            let key = note.userInfo?["key"] as? String ?? ""
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.remeasure { $0.row.message?.text.contains("![") == true || Self.showsImage($0, key: key) }
                }
            }
        }
    }

    private var diagramObserver: NSObjectProtocol?
    private var imageObserver: NSObjectProtocol?

    public override func fontRuntimeDidChange() {
        super.fontRuntimeDidChange()
        measured.removeAll()
        func refreshText(_ view: NSView) {
            if let markdown = view as? MarkdownView { markdown.fontRuntimeDidChange() }
            for child in view.subviews { refreshText(child) }
        }
        for view in visible.values { refreshText(view) }
        heights = items.map { height(of: $0) }
        relayout()
    }

    private func remeasure(containing marker: String) {
        remeasure { $0.row.message?.text.contains(marker) == true }
    }

    /// An open work row whose entry shows the image: its tool output, or the file it viewed.
    private static func showsImage(_ item: TimelineItem, key: String) -> Bool {
        guard case .work(let entries, _, _) = item.row.kind else { return false }
        return entries.contains { e in
            guard item.ui.expandedEntries.contains(e.id) else { return false }
            if key.hasPrefix("tool-output-image:") { return e.projectedItem.map { key.contains(":" + $0.sourceItemId.rawValue + ":") } == true }
            return key.hasPrefix("media-file:") && WorkLog.viewedImagePath(e).map { key.hasSuffix($0) } == true
        }
    }

    private func remeasure(where affected: (TimelineItem) -> Bool) {
        var changed = false
        for item in items {
            guard affected(item), measured.removeValue(forKey: item.id) != nil else { continue }
            changed = true
        }
        guard changed else { return }
        for view in visible.values { if let item = view.item, affected(item) { view.configure(item); applyFindHighlight(view); view.needsLayout = true } }
        heights = items.map { height(of: $0) }
        relayout()
    }

    /// Configures the visible rows again with the same items.
    private func reconfigureVisible() {
        for view in visible.values { if let item = view.item { view.configure(item); applyFindHighlight(view) } }
    }

    /// Run options own the speed, so changing the next prompt's model cannot change an active sweep.
    func setGlimmerModel(_ selection: ModelSelection?) {
        let fast = ShineLabelView.usesFastMode(selection)
        guard fast != context.fastGlimmer else { return }
        context.fastGlimmer = fast
        reconfigureVisible()
    }

    /// A hidden or closed timeline holds no web pages; its shown rows drop theirs themselves.
    public override func viewDidHide() { super.viewDidHide(); context.releasePages() }
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { context.releasePages() }
    }

    isolated deinit {
        if let clipObserver { NotificationCenter.default.removeObserver(clipObserver) }
    }

    // MARK: Data

    /// Replaces the rows. Unchanged rows keep their views and heights. `change` says which rows
    /// differ from the current ones, so an update on a long thread touches only those.
    func setItems(_ new: [TimelineItem], change: TimelineChange = .all) {
        if change == .thread {
            followsEnd = true
            lastNearTopId = nil
            context.releasePages()
        }
        let anchor = captureAnchor()
        let old = items
        items = new
        // Text-only patches retain the item index; rebuilding pairs is needed only when message rows change.
        switch change {
        case .rows(let changed):
            for rowIndex in changed {
                guard case .message(let message, _, _, _, _, _) = new[rowIndex].row.kind else { continue }
                var lower = 0, upper = minimap.items.count
                while lower < upper {
                    let middle = (lower + upper) / 2
                    if minimap.items[middle].rowIndex <= rowIndex { lower = middle + 1 } else { upper = middle }
                }
                guard lower > 0 else { continue }
                let index = lower - 1
                if message.role == .user { minimap.updatePreview(at: index, text: message.text, assistant: false) }
                else if minimap.items[index].assistantRowIndex == rowIndex { minimap.updatePreview(at: index, text: message.text, assistant: true) }
            }
        default: minimap.items = ThreadMinimapItem.derive(new.map(\.row))
        }
        layoutMinimap()
        let consistent = heights.count == old.count && tops.count == old.count
        if case .rows(let changed) = change, consistent, new.count == old.count {
            var first = new.count
            for i in changed {
                // A row on screen (the streaming answer) is measured now: an estimate here and the
                // real height in `tile` resized the document twice per update.
                let h = visible[new[i].id] != nil && laneFrame.width > 0 ? measure(i) : height(of: new[i])
                if h != heights[i] { heights[i] = h; first = min(first, i) }
            }
            if first < new.count { recomputeTops(from: first) }
        } else if case .tail(let first) = change, consistent, first <= old.count, first <= new.count {
            for item in old[first...] where indexById[item.id] ?? -1 >= first { indexById[item.id] = nil }
            for (i, item) in new[first...].enumerated() where indexById[item.id] == nil { indexById[item.id] = first + i }
            if measured.count > new.count * 2 { measured = measured.filter { indexById[$0.key] != nil } }
            heights.removeSubrange(first...)
            heights += new[first...].map { height(of: $0) }
            recomputeTops(from: first)
        } else if case .head(let replaced, let inserted) = change, consistent, replaced <= old.count, inserted <= new.count,
                  old.count - replaced == new.count - inserted {
            // Rows after the page keep their heights; the index moves for all of them.
            indexById = Dictionary(new.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
            if measured.count > new.count * 2 { measured = measured.filter { indexById[$0.key] != nil } }
            heights.replaceSubrange(0..<replaced, with: new[..<inserted].map { height(of: $0) })
            recomputeTops()
        } else {
            // Rows that kept their place and content keep their height; the rest are looked up or estimated.
            let sameIds = old.count == new.count && zip(old, new).allSatisfy { $0.id == $1.id }
            if !sameIds {
                indexById = Dictionary(new.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
                // Drop measurements of rows that left.
                if measured.count > new.count * 2 { measured = measured.filter { indexById[$0.key] != nil } }
            }
            let oldHeights = heights
            heights = new.enumerated().map { i, item in
                i < old.count && i < oldHeights.count && old[i].id == item.id && old[i] == item ? oldHeights[i] : height(of: item)
            }
            recomputeTops()
        }
        restore(anchor)
        OpenTiming.measure("timeline tile", "\(visible.count) row views") { tile() }
        disclosureRowId = nil
        updateMinimapPosition()
        if OpenTiming.active, !new.isEmpty { markFirstFrame() }
        if new.isEmpty != old.isEmpty { layoutEmptyPlaceholder() }
    }

    /// Development (CANDY_THREAD_TIMING): the next display refresh after the rows were placed, so
    /// after the Core Animation commit that carries them.
    private func markFirstFrame() {
        guard frameLink == nil, let window else { return }
        let link = window.displayLink(target: self, selector: #selector(frameLinkFired))
        link.add(to: .main, forMode: .common)
        frameLink = link
    }

    private var frameLink: CADisplayLink?

    @objc private func frameLinkFired(_ link: CADisplayLink) {
        link.invalidate()
        frameLink = nil
        OpenTiming.end("first frame", "\(items.count) rows, \(visible.count) row views, \(createdRowViews) created")
    }

    public func releaseFollowForNavigation() { followsEnd = false }

    /// Jump to a server search entry already present in the window of history.
    @discardableResult
    public func revealFindEntry(_ entryId: String) -> Bool {
        guard let i = indexById[entryId], i < tops.count else { return false }
        followsEnd = false
        if revealActiveFindMatch(entryId) { return true }
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, min(maxScroll, tops[i] - 60 - topClearance))))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        tile()
        _ = revealActiveFindMatch(entryId)
        return true
    }

    /// Scrolls to the row showing a work entry or message, as the image gallery's "Open in thread" does.
    @discardableResult
    public func revealEntry(containing entryId: String) -> Bool {
        let item = items.first { item in
            if item.id == entryId { return true }
            if case .work(let entries, _, _) = item.row.kind { return entries.contains { $0.id == entryId } }
            return false
        }
        return item.map { revealFindEntry($0.id) } ?? false
    }

    // T3 3814 MessagesTimeline.tsx:794-802 keeps endpoint headings mounted. A native rotor
    // can reach every loaded message without creating offscreen row views.
    public func rotor(_ rotor: NSAccessibilityCustomRotor, resultFor searchParameters: NSAccessibilityCustomRotor.SearchParameters) -> NSAccessibilityCustomRotor.ItemResult? {
        guard !isInert else { return nil }
        let current = searchParameters.currentItem?.itemLoadingToken as? String
        let start = current.flatMap { indexById[$0] }
        let forward = searchParameters.searchDirection == .next
        let step = forward ? 1 : -1
        let first = start.map { $0 + step } ?? (forward ? 0 : items.count - 1)
        for i in stride(from: first, to: forward ? items.count : -1, by: step) {
            guard let author = items[i].messageAuthor,
                  searchParameters.filterString.isEmpty || author.localizedCaseInsensitiveContains(searchParameters.filterString) else { continue }
            return NSAccessibilityCustomRotor.ItemResult(itemLoadingToken: items[i].id as NSString, customLabel: author)
        }
        return nil
    }

    public func accessibilityElement(withToken token: NSAccessibilityLoadingToken) -> (any NSAccessibilityElementProtocol)? {
        guard !isInert, let id = token as? String, let i = indexById[id], items[i].messageAuthor != nil,
              revealFindEntry(id) else { return nil }
        return visible[id]
    }

    // MARK: Geometry

    /// `resolveChatCanvasLayout` without previews (chatCanvasLayout.ts:26-60): 48px padding (12px
    /// below 640px), the lane at most 736px wide, centered.
    public var detailsCardLeft: CGFloat? { didSet { if detailsCardLeft != oldValue { relayout() } } }
    var laneFrame: (x: CGFloat, width: CGFloat) {
        let w = document.bounds.width
        // `px-3 sm:px-12`: the breakpoint is the viewport's width, not the column's, so the lane
        // keeps 48px beside an open right panel.
        let padding: CGFloat = viewportWidth >= 640 ? 48 : 12
        return ThreadDetailsPlacement.lane(width: w, maximum: ThreadChatWidth.maximum(ClientSettingsStore.shared.current.string("chatWidth"), dither: ThemeRuntime.isDither(dark: effectiveAppearance.isDark)), padding: padding, cardLeft: detailsCardLeft)
    }

    /// The window's width, or the outermost view's when there is no window (tests).
    private var viewportWidth: CGFloat {
        if let window { return window.frame.width }
        var view: NSView = self
        while let parent = view.superview { view = parent }
        return view.bounds.width
    }

    private func height(of item: TimelineItem) -> CGFloat {
        if let m = measured[item.id], m.width == laneFrame.width, m.item == item { return m.height }
        return Self.estimate(item, width: laneFrame.width)
    }

    /// `estimate`'s answer body for long text, from one pass over its bytes: lines of `perLine` points per character.
    static func estimatedLines(_ text: String, width: CGFloat, perLine: CGFloat = 7.5) -> CGFloat {
        // Rows ask again on every remeasure; the same text compares by its storage first.
        if let last = lastEstimate, last.width == width, last.perLine == perLine, last.text == text { return last.lines }
        let chars = max(1, width / perLine)
        var lines: CGFloat = 0, run = 0
        for byte in text.utf8 {
            if byte == 10 { lines += max(1, ceil(CGFloat(run) / chars)); run = 0 }
            else if byte & 0xC0 != 0x80 { run += 1 }
        }
        let total = lines + max(1, ceil(CGFloat(run) / chars))
        lastEstimate = (text, width, perLine, total)
        return total
    }
    private static var lastEstimate: (text: String, width: CGFloat, perLine: CGFloat, lines: CGFloat)?

    /// A first guess for rows not measured yet, from their kind and text length.
    static func estimate(_ item: TimelineItem, width: CGFloat) -> CGFloat {
        func lines(_ text: String, _ perLine: CGFloat) -> CGFloat {
            let chars = max(1, width / perLine)
            return text.split(separator: "\n", omittingEmptySubsequences: false).reduce(0) { $0 + max(1, ceil(CGFloat($1.count) / chars)) }
        }
        switch item.row.kind {
        case .message(let m, _, let meta, _, _, let summary):
            if m.role == .user {
                let marker: CGFloat = UserIntentMarkerView.presentation(m.inputIntent) == nil ? 0 : 16
                return marker + min(176, lines(m.text, 7.5 / 0.8) * 22.75) + 24 + 44
            }
            let card = summary.map { $0.files.isEmpty ? 0 : 16 + 56 + CGFloat($0.files.count) * 28 } ?? 0
            let body = m.text.utf8.count >= TimelineContext.backgroundBytes ? estimatedLines(m.text, width: width) : lines(m.text, 7.5)
            return body * 22.75 + 4 + card + (meta ? 46 : 8)
        case .assistantMeta: return 42
        case .proposedPlan(let p): return min(416, lines(p.planMarkdown, 7.5) * 22.75) + 140
        case .work(let entries, let group, _): return CGFloat(entries.count) * (group ? 24 : 28) + (group ? 4 : 8)
        case .workToggle, .thinking: return 36
        case .workLive: return 36
        case .pendingApproval: return 120
        case .working: return 43
        case .turnFold: return 41.75
        case .attemptFold: return 42
        case .contextCompaction: return 40
        case .event: return 48
        case .htmlRender(let page):
            let box = Double(max(0, width - 8))
            return CGFloat(page.frameHeight(width: box, contentHeight: item.ui.htmlHeights.height(width: box))) + 8
        case .mcpApp: return CGFloat(item.ui.webContentHeight ?? McpAppReference.defaultHeight) + 8
        }
    }

    /// Row tops from `first` on; the ones above it stay.
    private func recomputeTops(from first: Int = 0) {
        let start = tops.count == items.count ? min(first, items.count) : 0
        tops.removeSubrange(start...)
        tops.reserveCapacity(items.count)
        var y = start == 0 ? topInset : tops[start - 1] + heights[start - 1]
        for h in heights[start...] {
            tops.append(y)
            y += h
        }
        footerView?.frame = NSRect(x: TL.snap(laneFrame.x), y: y, width: laneFrame.width, height: footerHeight)
        let height = y + footerHeight + Self.footer + bottomInset
        if document.frame.height != height || document.frame.width != scrollView.contentSize.width {
            adjusting = true
            document.setFrameSize(NSSize(width: scrollView.contentSize.width, height: height))
            adjusting = false
        }
    }

    private var contentHeight: CGFloat { document.frame.height }
    private var viewport: NSRect { scrollView.contentView.bounds }
    private var maxScroll: CGFloat { max(0, contentHeight - viewport.height) }

    /// First row whose bottom is below `y`.
    private func lowerBound(_ y: CGFloat) -> Int {
        var lo = 0, hi = items.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if tops[mid] + heights[mid] <= y { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    private func range(_ rect: NSRect) -> Range<Int> {
        guard !items.isEmpty else { return 0..<0 }
        let lo = lowerBound(rect.minY)
        var hi = lo
        while hi < items.count, tops[hi] < rect.maxY { hi += 1 }
        return lo..<hi
    }

    // MARK: Anchoring

    private struct Anchor { var id: String; var offset: CGFloat; var disclosure = false }

    private func captureAnchor() -> Anchor? {
        if let id = disclosureRowId, let i = indexById[id], i < tops.count, tops.count == items.count {
            return Anchor(id: id, offset: tops[i] - viewport.minY, disclosure: true)
        }
        guard !followsEnd, !items.isEmpty, tops.count == items.count else { return nil }
        let i = min(lowerBound(viewport.minY), items.count - 1)
        return Anchor(id: items[i].id, offset: tops[i] - viewport.minY)
    }

    private func restore(_ anchor: Anchor?) {
        if let anchor, anchor.disclosure, let i = indexById[anchor.id], i < tops.count {
            setScroll(tops[i] - anchor.offset)
            followsEnd = maxScroll - viewport.minY <= 1
        } else if followsEnd {
            setScroll(maxScroll)
        } else if let anchor, let i = indexById[anchor.id] {
            setScroll(tops[i] - anchor.offset)
        } else {
            setScroll(viewport.minY)
        }
    }

    private func setScroll(_ y: CGFloat) {
        let target = min(max(0, y), maxScroll)
        guard target != viewport.minY else { return }
        adjusting = true
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: target))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        adjusting = false
        // A scroll the timeline makes itself (opening at the end, anchoring) moves the minimap too.
        updateMinimapPosition()
    }

    // MARK: Layout and tiling

    public override func layout() {
        OpenTiming.measure("timeline layout", "\(items.count) rows") { layoutNow() }
    }

    private func layoutNow() {
        super.layout()
        // A resize is not a scroll: a terminal drawer or banner that shrinks the viewport, often in the same
        // pass as a thread switch, must not drop `followsEnd` and leave the newest rows under the composer.
        let wasFollowing = followsEnd
        adjusting = true
        scrollView.frame = bounds
        adjusting = false
        let width = scrollView.contentSize.width
        if wasFollowing, width == laidOutWidth, document.frame.width == width {
            followsEnd = true
            setScroll(maxScroll)
            updatePill()
        }
        if width != laidOutWidth || document.frame.width != width {
            let anchor = captureAnchor()
            laidOutWidth = width
            adjusting = true
            document.setFrameSize(NSSize(width: width, height: document.frame.height))
            adjusting = false
            heights = items.map { height(of: $0) }
            if let sized = footerView as? TimelineSizedFooter { footerHeight = sized.height(forWidth: laneFrame.width) }
            recomputeTops()
            restore(anchor)
        }
        tile(relayoutAll: true)
        layoutPill()
        layoutHeader()
        layoutMinimap()
    }

    private func relayout() {
        guard !items.isEmpty || tops.isEmpty == false else { return }
        let anchor = captureAnchor()
        recomputeTops()
        restore(anchor)
        tile()
    }

    private func didScroll() {
        guard !adjusting else { return }
        followsEnd = maxScroll - viewport.minY <= 1
        updatePill()
        tile()
        updateMinimapPosition()
        minimap.revealForScroll()
        requestEarlierIfNearTop()
    }

    private func requestEarlierIfNearTop() {
        guard !adjusting else { return }
        if viewport.minY < Self.nearTop, let first = items.first?.id, first != lastNearTopId, onNearTop != nil {
            lastNearTopId = first
            onNearTop?()
        }
    }

    private func layoutMinimap() {
        let gutter = laneFrame.x
        minimap.isHidden = minimap.items.count < 2 || gutter <= 12
        minimap.persistentGutter = gutter >= 48
        let height = min(CGFloat(max(1, minimap.items.count - 1)) * 8, max(1, bounds.height - topClearance - 288))
        // Redesign pads the column for its backing and viewport band, and keeps it as wide as its widest tick; the ticks
        // stay where they were.
        let pad = minimap.padding
        minimap.frame = NSRect(x: 12, y: topClearance + (bounds.height - topClearance - height) / 2, width: min(pad > 0 ? 24 : 40, max(0, gutter - 12)), height: height)
            .insetBy(dx: -pad, dy: -pad)
        updateMinimapPosition()
    }
    /// The first turn on screen is the current one, else the last above it; every turn on screen lights its strip
    /// (`resolveTimelineMinimapCurrentIndex`, MessagesTimeline.logic.ts:383-409).
    private func updateMinimapPosition() {
        let top = viewport.minY + topClearance, bottom = viewport.maxY
        var current: Int?, preceding: Int?, inView = IndexSet()
        for (index, item) in minimap.items.enumerated() where item.rowIndex < tops.count && item.rowIndex < heights.count {
            let rowTop = tops[item.rowIndex]
            if rowTop < bottom, rowTop + max(1, heights[item.rowIndex]) > top {
                inView.insert(index)
                if current == nil { current = index }
            } else if rowTop <= top {
                preceding = index
            }
        }
        minimap.currentIndex = current ?? preceding
        minimap.inView = inView
    }

    /// Lays out rows in the visible rect plus overscan. Rows measured for the first time can change
    /// height; the anchor then puts the viewport back, and the loop measures what came into view.
    private func tile(relayoutAll: Bool = false) {
        guard laneFrame.width > 0 else { return }
        // A scroll notification during tiling (the document resizing, a row measuring itself)
        // must not tile inside this pass: both would recycle the same views. Run once more after.
        guard !tiling else { retile = true; return }
        tiling = true
        defer {
            tiling = false
            if retile { retile = false; tile() }
        }
        let lane = laneFrame
        var wanted = range(viewport.insetBy(dx: 0, dy: -Self.overscan))
        // Each pass that changes anything measured at least one new row, so this ends; the cap only
        // bounds a pathological thread. Every placed row is measured below either way.
        for _ in 0..<64 {
            let anchor = captureAnchor()
            var changed = false
            for i in wanted {
                let view = viewFor(i)
                let item = items[i]
                let h: CGFloat
                if let m = measured[item.id], m.width == lane.width, m.item == item {
                    h = m.height
                } else {
                    h = view.height(forWidth: lane.width)
                    measured[item.id] = (lane.width, item, h)
                }
                if h != heights[i] { heights[i] = h; changed = true }
            }
            guard changed else { break }
            recomputeTops()
            restore(anchor)
            wanted = range(viewport.insetBy(dx: 0, dy: -Self.overscan))
        }
        let ids = Set(wanted.map { items[$0].id })
        for (id, view) in visible where !ids.contains(id) {
            visible[id] = nil
            recycle(view)
        }
        // Rows that came into range on the last pass are measured before they are placed, or an
        // estimated height would overlap the next row.
        var late = false
        for i in wanted where !isMeasured(items[i], lane.width) {
            let h = viewFor(i).height(forWidth: lane.width)
            measured[items[i].id] = (lane.width, items[i], h)
            if h != heights[i] { heights[i] = h; late = true }
        }
        if late { recomputeTops() }
        for i in wanted {
            let view = viewFor(i)
            let frame = NSRect(x: TL.snap(lane.x), y: TL.snap(tops[i]), width: lane.width, height: heights[i])
            view.setContentVisible(frame.intersects(viewport))
            if view.frame != frame || relayoutAll { view.frame = frame; view.needsLayout = true }
        }
    }

    /// Configures row `i`'s view and returns its height at the lane width, cached in `measured`.
    private func measure(_ i: Int) -> CGFloat {
        let item = items[i], width = laneFrame.width
        if let m = measured[item.id], m.width == width, m.item == item { return m.height }
        let h = viewFor(i).height(forWidth: width)
        measured[item.id] = (width, item, h)
        return h
    }

    private func isMeasured(_ item: TimelineItem, _ width: CGFloat) -> Bool {
        guard let m = measured[item.id] else { return false }
        return m.width == width && m.item == item
    }

    private func viewFor(_ i: Int) -> TimelineRowView {
        let item = items[i]
        if let view = visible[item.id] {
            // An id can change kind (the live activity row is `thinking`, then `workLive`). The old
            // view class can't draw the new kind, so it goes back to its own pool.
            if view.kind == Self.kind(item.row) {
                if view.item != item { configureCount += 1; view.configure(item); applyFindHighlight(view) }
                return view
            }
            visible[item.id] = nil
            recycle(view)
        }
        let view = dequeue(Self.kind(item.row))
        configureCount += 1
        view.configure(item); applyFindHighlight(view)
        visible[item.id] = view
        return view
    }

    static func kind(_ row: TimelineRow) -> Kind {
        switch row.kind {
        case .message(let m, _, _, _, _, _): m.role == .user ? (m.workflowOpening ? .workflowOpening : .user) : .assistant
        case .assistantMeta: .meta
        case .proposedPlan: .plan
        case .work: .work
        case .workToggle: .toggle
        case .workLive: .live
        case .thinking: .thinking
        case .pendingApproval: .approval
        case .working: .working
        case .turnFold: .turnFold
        case .attemptFold: .attemptFold
        case .contextCompaction: .compaction
        case .event(let p, _, _):
            p.item.type == .secretRequest ? .secret : p.item.type == .linkRequest ? .linkRequest : p.item.type == .subagent ? .subagent : .event
        case .htmlRender: .htmlRender
        case .mcpApp: .mcpApp
        }
    }

    private func dequeue(_ kind: Kind) -> TimelineRowView {
        if let view = pools[kind]?.popLast() {
            view.pooled = false
            document.addSubview(view)
            view.isHidden = false
            return view
        }
        createdRowViews += 1
        let view: TimelineRowView = switch kind {
        case .user: UserMessageRowView()
        case .workflowOpening: WorkflowOpeningRowView()
        case .assistant: AssistantMessageRowView()
        case .meta: AssistantMetaRowView()
        case .plan: PlanRowView()
        case .work: WorkRowView()
        case .toggle: WorkToggleRowView()
        case .live: WorkLiveRowView()
        case .thinking: ThinkingRowView()
        case .approval: PendingApprovalRowView()
        case .working: WorkingRowView()
        case .turnFold: TurnFoldRowView()
        case .attemptFold: AttemptFoldRowView()
        case .compaction: CompactionRowView()
        case .event: EventRowView()
        case .subagent: SubagentCardRowView()
        case .secret: SecretRequestRowView()
        case .linkRequest: LinkRequestRowView()
        case .htmlRender: HtmlRenderRowView()
        case .mcpApp: McpAppRowView()
        }
        view.context = context
        view.kind = kind
        document.addSubview(view)
        return view
    }

    private func recycle(_ view: TimelineRowView) {
        guard !view.pooled else { return }
        view.pooled = true
        // NSView's `prepareForReuse` unhides the view and resets its alpha, so it runs first.
        // The other order left every recycled row on screen at its old frame.
        view.prepareForReuse()
        view.isHidden = true
        parked.addSubview(view)
        if let kind = view.kind { pools[kind, default: []].append(view) }
    }

    // MARK: Scroll to end (H-timeline-visuals.md 6.2)

    public func scrollToEnd(animated: Bool) {
        followsEnd = true
        updatePill()
        guard animated, !Motion.reduced else { setScroll(maxScroll); tile(); return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            ctx.timingFunction = Motion.easeInOut
            scrollView.contentView.animator().setBoundsOrigin(NSPoint(x: 0, y: maxScroll))
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.scrollView.reflectScrolledClipView(self.scrollView.contentView)
                self.followsEnd = true
                self.updatePill()
            }
        }
    }

    /// Scrolls to a share of the scrollable height (0 top, 1 end). Tests and previews.
    func scroll(toFraction f: CGFloat) {
        followsEnd = f >= 1
        // Measure everything first so the fraction means the same as in a browser that laid out all rows.
        let lane = laneFrame.width
        for (i, item) in items.enumerated() {
            if let m = measured[item.id], m.width == lane, m.item == item { heights[i] = m.height; continue }
            // Off-screen rows borrow a pooled view and give it back.
            let view = visible[item.id] != nil ? viewFor(i) : dequeue(Self.kind(item.row))
            if view.item != item { configureCount += 1; view.configure(item); applyFindHighlight(view) }
            let h = view.height(forWidth: lane)
            measured[item.id] = (lane, item, h)
            heights[i] = h
            if visible[item.id] == nil { recycle(view) }
        }
        recomputeTops()
        setScroll(maxScroll * f)
        tile()
        updatePill()
    }

    /// Shown when away from the end; showing waits 150ms so it doesn't flash while a thread opens.
    private func updatePill() {
        pillWork?.cancel()
        if followsEnd || items.isEmpty {
            pill.isHidden = true
            return
        }
        guard pill.isHidden else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.followsEnd else { return }
            self.pill.isHidden = false
            self.layoutPill()
        }
        pillWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// `bottom: clearance + 4px` plus the wrapper's 6px padding, centered on the canvas.
    private func layoutPill() {
        let size = pill.intrinsicContentSize
        pill.frame = NSRect(x: ((bounds.width - size.width) / 2).rounded(), y: bounds.height - bottomInset - 10 - size.height,
                            width: size.width, height: size.height)
    }

    // MARK: Checks

    /// What breaks the tiling contract: stray or misplaced row views, overlaps, pooled views on
    /// screen, a wrong document height, subviews past a row's height. Empty when all is well.
    /// The tests call it after every step; `debugReport()` prints it for the live app.
    func layoutProblems() -> [String] {
        var problems: [String] = []
        let lane = laneFrame
        if Set(items.map(\.id)).count != items.count { problems.append("duplicate row ids") }
        let expectedHeight = topInset + heights.reduce(0, +) + footerHeight + Self.footer + bottomInset
        if abs(document.frame.height - expectedHeight) > 0.01 { problems.append("document height \(document.frame.height), rows say \(expectedHeight)") }
        let pooled = Set(pools.values.flatMap { $0 }.map(ObjectIdentifier.init))
        var placed: [(String, NSRect)] = []
        for case let view as TimelineRowView in document.subviews {
            let id = view.item?.id ?? "nil"
            if pooled.contains(ObjectIdentifier(view)) {
                if !view.isHidden { problems.append("pooled view \(id) is on screen") }
                continue
            }
            guard !view.isHidden else { continue }
            guard let item = view.item, visible[item.id] === view, let i = indexById[item.id] else {
                problems.append("stray view \(id) at \(view.frame)"); continue
            }
            if view.kind != Self.kind(items[i].row) { problems.append("view of kind \(String(describing: view.kind)) shows \(id)") }
            if view.item != items[i] { problems.append("view \(id) shows an old item") }
            let frame = NSRect(x: TL.snap(lane.x), y: TL.snap(tops[i]), width: lane.width, height: heights[i])
            if view.frame != frame { problems.append("view \(id) at \(view.frame), row at \(frame)") }
            // Pending layout is fine; what a laid-out row draws past its height is not.
            view.layoutSubtreeIfNeeded()
            let own = view.height(forWidth: lane.width)
            if abs(own - heights[i]) > 0.01 { problems.append("view \(id) measures \(own), row has \(heights[i])") }
            for sub in view.subviews where !sub.isHidden && sub.frame.height > 0 && sub.frame.maxY > own + 0.5 {
                problems.append("view \(id): \(type(of: sub)) ends at \(sub.frame.maxY), past \(own)")
            }
            placed.append((id, view.frame))
        }
        placed.sort { $0.1.minY < $1.1.minY }
        for (a, b) in zip(placed, placed.dropFirst()) where b.1.minY < a.1.maxY - 0.5 {
            problems.append("\(a.0) \(a.1) overlaps \(b.0) \(b.1)")
        }
        for id in visible.keys where indexById[id] == nil { problems.append("visible holds gone row \(id)") }
        return problems
    }

    /// Row ids, kinds and frames on screen plus `layoutProblems()`, for checking the live app.
    public func debugReport() -> String {
        var lines = ["timeline: \(items.count) rows, viewport \(viewport), document \(document.frame.size), followsEnd \(followsEnd)"]
        let shown = visible.values.filter { !$0.isHidden }.sorted { $0.frame.minY < $1.frame.minY }
        for view in shown {
            lines.append("  \(view.item?.id ?? "nil") \(String(describing: view.kind)) \(view.frame)")
        }
        let problems = layoutProblems()
        lines.append(problems.isEmpty ? "no problems" : "PROBLEMS:")
        lines += problems.map { "  " + $0 }
        return lines.joined(separator: "\n")
    }

    // MARK: Test hooks

    /// Scrolls by `dy` from the current position (tests line a row up with a reference).
    func scroll(by dy: CGFloat) {
        followsEnd = false
        setScroll(viewport.minY + dy)
        tile()
        updatePill()
    }

    func view(forRow id: String) -> TimelineRowView? { visible[id] }
    var liveViewCount: Int { visible.count }
    var isPillVisible: Bool { !pill.isHidden }
    var documentHeight: CGFloat { contentHeight }
}

/// A timeline footer whose height follows the lane's width, such as one holding a guest's waiting messages.
@MainActor protocol TimelineSizedFooter: NSView {
    func height(forWidth width: CGFloat) -> CGFloat
}
