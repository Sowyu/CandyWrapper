import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// The thread list: `SidebarGroup` (`p-2`, `pt-0` under the fixed header) around a `flex flex-col gap-px` list.
/// Virtualized: only rows inside the clip view plus `overscan` exist, recycled per kind, and an update
/// reconfigures only rows whose model changed. Row motion copies Sidebar.motion.ts.
public final class SidebarListView: DSView {
    static let padding: CGFloat = 8
    static let gap: CGFloat = 1
    /// Extra points laid out above and below the visible rect.
    static let overscan: CGFloat = 160

    public private(set) var items: [SidebarItem] = []
    private(set) var tops: [CGFloat] = []
    private(set) var indexByKey: [String: Int] = [:]
    private(set) var visible: [String: SidebarRowBase] = [:]
    private var pools: [SidebarItem.Kind: [SidebarRowBase]] = [:]
    /// Rows fading out after removal; they leave the pool until their animation ends.
    private var exiting: Set<ObjectIdentifier> = []
    private var clipObserver: NSObjectProtocol?
    /// Keyboard focus, as an item key. Arrows move it, Enter opens it.
    public private(set) var focusedKey: String?
    var nowMs: Int64 = 0

    var onOpen: (@MainActor (ThreadId) -> Void)?
    var onToggleShelf: (@MainActor (SidebarShelf) -> Void)?
    var onShowMore: (@MainActor () -> Void)?
    var onOpenDraft: (@MainActor (String) -> Void)?
    var onDiscardDraft: (@MainActor (String) -> Void)?
    var onOpenSearchResult: (@MainActor (ThreadId) -> Void)?
    /// The empty list's Add project button.
    var onAddProject: (@MainActor () -> Void)?
    /// The pointer moved over a search result (`onMouseMove` highlights it).
    var onHighlightSearchResult: (@MainActor (Int) -> Void)?
    var rowActions = SidebarRowActions()
    var onVisibleRowsChange: (@MainActor () -> Void)?
    /// The one rename field, lent to the row being renamed.
    /// Built on the first rename.
    let lazyRenameField = LazyView { SidebarRenameFieldView() }
    var renameField: SidebarRenameFieldView { lazyRenameField.view }
    /// The hover card's content for a thread, nil for none.
    var hoverCard: (@MainActor (ThreadId) -> SidebarThreadHoverCardModel?)?
    private var hoverWork: DispatchWorkItem?
    private var hoverPopup: (id: ThreadId, popup: OpenPopup)?
    /// When the last card closed: within `timeout` (400ms) the next one opens at once.
    private var hoverClosedAt: Date?

    /// Counters for tests: how many row views were made and how many configure calls ran.
    public private(set) var createdRowViews = 0
    public private(set) var configureCount = 0

    public override var acceptsFirstResponder: Bool { true }
    public override var canBecomeKeyView: Bool { true }

    // MARK: Data

    /// Replaces the items. Rows whose model is unchanged keep their view untouched; moved rows slide.
    public func setItems(_ new: [SidebarItem], animated: Bool) {
        var oldTops = Dictionary(uniqueKeysWithValues: items.indices.map { (items[$0].key, tops[$0]) })
        // After a drop the rows glide from where the preview left them, not from their old slots.
        let released = releasedTops
        releasedTops = nil
        if let released { oldTops.merge(released) { $1 } }
        let oldVisible = visible
        let oldItems = Dictionary(uniqueKeysWithValues: items.map { ($0.key, $0) })
        items = new
        recomputeGeometry()
        let shouldAnimate = (animated || released != nil) && window != nil && !Motion.reduced && !oldTops.isEmpty
        // Rows that left the list fade out where they were.
        var faded = 0
        for (key, view) in oldVisible where indexByKey[key] == nil {
            visible[key] = nil
            if shouldAnimate, faded < Self.maxFadedRows {
                faded += 1
                fadeOut(view)
            } else {
                recycle(view)
            }
        }
        // Changed rows that stay visible get the new model; nothing else is touched. A row that
        // changed shape (card to slim on snooze or settle, slim to card on unsnooze) needs the other
        // view class: its old view goes back to its own pool and `tile` dequeues the right one, which
        // still slides from the old place. Configuring the old view kept a card drawn in the slim
        // shelves and put card views in the slim pool.
        for (key, view) in visible {
            guard let i = indexByKey[key] else { continue }
            if view.item?.kind != items[i].kind {
                visible[key] = nil
                recycle(view)
            } else if oldItems[key] != items[i] || view.item != items[i] {
                configure(view, items[i])
            }
        }
        if sort != nil {
            tile(oldTops: nil)
            rebuildSortPlan(animated: animated)
        } else {
            tile(oldTops: shouldAnimate ? oldTops : nil)
        }
    }

    static let maxFadedRows = 40
    private static let duration: CFTimeInterval = 0.15
    private static let easing = CAMediaTimingFunction(name: .easeOut)

    private func recomputeGeometry() {
        tops = []
        indexByKey = [:]
        var y: CGFloat = 0
        let firstShelf = items.firstIndex { if case .shelfHeader = $0 { true } else { false } }
        let natural = items.reduce(0) { $0 + $1.height } + CGFloat(max(0, items.count - 1)) * Self.gap + Self.padding
        let room = max(0, viewportHeight - natural)
        for (i, item) in items.enumerated() {
            if i == firstShelf { y += room } // `mt-auto`: shelves sit at the bottom of a short list
            tops.append(y)
            indexByKey[item.key] = i
            y += item.height + Self.gap
        }
        let height = max(viewportHeight, (items.isEmpty ? 0 : y - Self.gap) + Self.padding)
        if frame.height != height { setFrameSize(NSSize(width: frame.width, height: height)) }
    }

    private var viewportHeight: CGFloat { enclosingScrollView?.contentView.bounds.height ?? 0 }

    // MARK: Tiling

    /// A list torn down mid drag stops its sort, and with it the Escape and autoscroll timers.
    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil, sort != nil { cancelSort() }
    }

    public override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if let clipObserver { NotificationCenter.default.removeObserver(clipObserver) }
        guard let clip = superview as? NSClipView else { return }
        clip.postsBoundsChangedNotifications = true
        clip.postsFrameChangedNotifications = true
        clipObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tile(oldTops: nil) }
        }
    }

    public override func layout() {
        super.layout()
        recomputeGeometry()
        tile(oldTops: nil, relayoutAll: true)
    }

    /// Indices of items intersecting the visible rect plus overscan.
    var visibleRange: Range<Int> {
        guard !items.isEmpty else { return 0..<0 }
        let rect = visibleRect.insetBy(dx: 0, dy: -Self.overscan)
        let lo = lowerBound(rect.minY)
        var hi = lo
        while hi < items.count, tops[hi] < rect.maxY { hi += 1 }
        return lo..<hi
    }

    /// First item whose bottom is below `y` (binary search over the sorted tops).
    private func lowerBound(_ y: CGFloat) -> Int {
        var lo = 0, hi = items.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if tops[mid] + items[mid].height < y { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// The models of rows currently on screen (overscan excluded), for the label timer.
    public var visibleRowModels: [SidebarRowModel] {
        let rect = visibleRect
        return items.indices.compactMap { i in
            guard tops[i] < rect.maxY, tops[i] + items[i].height > rect.minY, case .row(let r) = items[i] else { return nil }
            return r
        }
    }

    func frame(at i: Int) -> NSRect {
        NSRect(x: Self.padding, y: tops[i], width: max(0, bounds.width - Self.padding * 2), height: items[i].height)
    }

    func tile(oldTops: [String: CGFloat]?, relayoutAll: Bool = false) {
        let range = visibleRange
        var wanted = Set(range.map { items[$0].key })
        // The lifted row stays alive while autoscroll carries its slot out of view.
        if let sort, sort.sortable, indexByKey[sort.key] != nil { wanted.insert(sort.key) }
        for (key, view) in visible where !wanted.contains(key) {
            visible[key] = nil
            recycle(view)
        }
        var changed = false
        var entering = 0
        for i in range {
            let item = items[i]
            let target = frame(at: i)
            if let view = visible[item.key] {
                // The drag preview owns the rows' places.
                if sort?.sortable == true { if relayoutAll { view.frame.size.width = target.width }; continue }
                let old = view.frame
                if old != target || relayoutAll { view.frame = target }
                if let oldTops, let previous = oldTops[item.key], previous != target.minY {
                    slide(view, from: previous - target.minY)
                }
            } else {
                let view = dequeue(item.kind)
                view.frame = target
                configure(view, item)
                visible[item.key] = view
                changed = true
                if let oldTops, let previous = oldTops[item.key] {
                    // A row that came back in its other shape still travels from its old place.
                    if previous != target.minY { slide(view, from: previous - target.minY) }
                } else if oldTops != nil, entering < Self.maxFadedRows {
                    entering += 1
                    fadeIn(view)
                }
            }
        }
        if changed, sort?.sortable == true { placeSorted(animated: false) }
        if changed || oldTops != nil { onVisibleRowsChange?() }
    }

    private func dequeue(_ kind: SidebarItem.Kind) -> SidebarRowBase {
        if let view = pools[kind]?.popLast() {
            view.isHidden = false
            return view
        }
        createdRowViews += 1
        let view: SidebarRowBase
        switch kind {
        case .card:
            let card = SidebarCardRowView()
            view = card
        case .slim: view = SidebarSlimRowView()
        case .shelf:
            let shelf = SidebarShelfRowView()
            shelf.onToggle = { [weak self] in self?.onToggleShelf?($0) }
            view = shelf
        case .showMore: view = SidebarShowMoreRowView()
        case .draft:
            let draft = SidebarDraftRowView()
            draft.onDiscard = { [weak self] id in self?.onDiscardDraft?(id) }
            view = draft
        case .divider: view = SidebarDividerRowView()
        case .searchResult:
            let result = SidebarSearchResultRowView()
            result.onHover = { [weak self] index in self?.onHighlightSearchResult?(index) }
            view = result
        case .emptyText: view = SidebarEmptyTextRowView()
        case .noProjects:
            let row = SidebarNoProjectsRowView()
            row.onAddProject = { [weak self] in self?.onAddProject?() }
            view = row
        }
        if kind == .searchResult {
            view.onHoverChange = { [weak self] row, hovered in self?.rowHoverChanged(row, hovered) }
        }
        if kind == .card || kind == .slim {
            view.onHoverChange = { [weak self] row, hovered in self?.rowHoverChanged(row, hovered) }
            view.onBeginDrag = { [weak self] row, id, event, press in self?.beginThreadDrag(row, id, event: event, press: press) }
        }
        view.onOpen = { [weak self, weak view] in
            guard let self, let item = view?.item else { return }
            self.open(item)
        }
        addSubview(view)
        return view
    }

    private func recycle(_ view: SidebarRowBase) {
        if let id = Self.hoverThreadId(view.item), hoverPopup?.id == id { closeHoverCard() }
        lendRenameField(to: view, nil)
        view.prepareForReuse()
        view.layer?.removeAllAnimations()
        view.isHidden = true
        view.isKeyboardFocused = false
        if let kind = view.item?.kind { pools[kind, default: []].append(view) }
    }

    private func configure(_ view: SidebarRowBase, _ item: SidebarItem) {
        configureCount += 1
        if let card = view as? SidebarCardRowView { card.actions = rowActions; card.nowMs = nowMs }
        if let slim = view as? SidebarSlimRowView { slim.actions = rowActions }
        if case .row(let r) = item, r.isRenaming { lendRenameField(to: view, item) } else { lendRenameField(to: view, nil) }
        view.configure(item)
        view.isKeyboardFocused = item.key == focusedKey
    }

    private func lendRenameField(to view: SidebarRowBase, _ item: SidebarItem?) {
        if item != nil {
            view.renameField = renameField
        } else if view.renameField != nil {
            view.renameField = nil
            if let field = lazyRenameField.loaded, field.superview === view { field.removeFromSuperview() }
        }
    }

    // MARK: Hover card (`<Tooltip>` around each thread row, Sidebar.tsx:1966-2216)

    /// `TooltipProvider delay={150} closeDelay={0} timeout={400}`, `side="right" align="start" sideOffset={4}`.
    private func rowHoverChanged(_ row: SidebarRowBase, _ hovered: Bool) {
        hoverWork?.cancel()
        guard hovered, let id = Self.hoverThreadId(row.item) else { closeHoverCard(); return }
        if let open = hoverPopup, open.id == id { return }
        let instant = hoverClosedAt.map { Date().timeIntervalSince($0) < 0.4 } ?? false
        let work = DispatchWorkItem { [weak self, weak row] in
            guard let self, let row, row.state.hovered, Self.hoverThreadId(row.item) == id else { return }
            self.showHoverCard(id, over: row, instant: instant)
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (instant ? 0 : 0.15), execute: work)
    }

    /// The thread a row's card describes: a thread row not being renamed, or a search result, which gets the
    /// same card "to disambiguate identically-titled results" (Sidebar.tsx:2259-2261, 2364-2378).
    private static func hoverThreadId(_ item: SidebarItem?) -> ThreadId? {
        switch item {
        case .row(let r)?: r.isRenaming ? nil : r.id
        case .searchResult(let r)?: r.id
        default: nil
        }
    }

    private func showHoverCard(_ id: ThreadId, over row: SidebarRowBase, instant: Bool = false) {
        // The snooze menu's open state disables the card (`disabled={snoozeMenuOpen}`).
        if let card = row as? SidebarCardRowView, card.snoozeButton.state.popupOpen { return }
        // Nothing under a dialog or the palette shows a card (their backdrops cover the rows).
        if window?.contentView?.subviews.contains(where: { $0 is ModalHost || $0 is CommandPaletteOverlay }) == true { return }
        guard let model = hoverCard?(id), let host = row.popupHost else { return }
        closeHoverCard()
        let popup = host.open(SidebarThreadHoverCardView(model), trigger: row,
                              placement: PopupPlacement(side: .right, align: .start, sideOffset: 4),
                              // `data-instant`: a card that follows another within the provider timeout skips the motion.
                              motion: instant ? .none : .tooltip, pressesTrigger: false, returnsFocus: false, passive: true)
        hoverPopup = (id, popup)
    }

    /// Data the open card waits on arrived (the checkout's branch): the card updates in place.
    func refreshHoverCard() {
        guard let open = hoverPopup, let card = open.popup.content as? SidebarThreadHoverCardView,
              let model = hoverCard?(open.id), card.branchMismatch != model.branchMismatch, let window else { return }
        card.branchMismatch = model.branchMismatch
        PopupHost.host(for: window).reposition(open.popup)
    }

    func closeHoverCard() {
        hoverWork?.cancel()
        guard let open = hoverPopup else { return }
        hoverPopup = nil
        hoverClosedAt = Date()
        if let window { PopupHost.host(for: window).close(open.popup, returnFocus: false) }
    }

    // MARK: Files dropped on a row (sidebarPendingFileDropStore.ts, `makeWorkspaceFileDropHandlers`)

    /// Files dropped on a thread row: the app opens the thread and attaches them in its composer.
    var onFileDrop: (@MainActor (ThreadId, [URL]) -> Void)?
    private weak var fileDragRow: SidebarRowBase?

    private func fileDropRow(_ sender: any NSDraggingInfo) -> SidebarRowBase? {
        guard onFileDrop != nil, sender.draggingSource == nil || !(sender.draggingSource is SidebarListView),
              sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else { return nil }
        let point = convert(sender.draggingLocation, from: nil)
        return visible.values.first { row in
            guard case .row? = row.item, !row.isHidden else { return false }
            return row.frame.contains(point)
        }
    }

    private func setFileDragRow(_ row: SidebarRowBase?) {
        guard row !== fileDragRow else { return }
        fileDragRow?.isFileDragOver = false
        row?.isFileDragOver = true
        fileDragRow = row
    }

    public override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    // MARK: Thread drags (SidebarSortSession.swift)

    /// The drag in flight, nil at rest.
    var sort: SidebarSortSession?
    /// Where the rows stood when a drop released them, until the new order arrives.
    var releasedTops: [String: CGFloat]?
    /// The AppKit drag that Escape cancelled. It runs on until the release, carrying nothing.
    weak var cancelledDrag: NSDraggingSession?
    /// The list state the drag preview reads.
    var sortContext = SidebarSortPlanner.Context()
    /// Reads the list state for a drag; called at pickup and when the list changes under it.
    var sortContextProvider: (() -> SidebarSortPlanner.Context)?
    /// The row can be picked up: its server stores a pin order (`draggableThreadKeys`, Sidebar.tsx:2808-2810).
    public var canSortThread: ((ThreadId) -> Bool)?
    /// `planSidebarThreadDrop(...).kind !== "none"` for the lifted row on this target.
    public var canSortDrop: ((ThreadId, SidebarSection, SidebarDropTarget) -> Bool)?
    /// A drop in the list: the thread, the section it left and where it lands.
    public var onSortDrop: ((ThreadId, SidebarSection, SidebarDropTarget) -> Void)?

    public override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if sender.draggingSource as? SidebarListView === self {
            return sort.map { $0.sortable && !$0.outside } == true ? .move : []
        }
        let row = fileDropRow(sender)
        setFileDragRow(row)
        return row == nil ? [] : .copy
    }

    public override func draggingExited(_ sender: (any NSDraggingInfo)?) { setFileDragRow(nil) }
    public override func draggingEnded(_ sender: any NSDraggingInfo) { setFileDragRow(nil) }

    public override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        defer { setFileDragRow(nil) }
        // The session's end commits the sort (`endSort`).
        if sender.draggingSource as? SidebarListView === self { return sort != nil }
        guard let row = fileDropRow(sender), case .row(let r)? = row.item,
              let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }
        onFileDrop?(r.id, urls)
        return true
    }

    /// The row's frame in the list, nil when the thread has no row.
    func rowFrame(_ id: ThreadId) -> NSRect? {
        indexByKey["thread:\(id.rawValue)"].map { frame(at: $0) }
    }

    /// Re-applies the clock to on-screen Working rows without rebuilding anything.
    func tickWorkingRows() {
        for view in visible.values {
            guard let card = view as? SidebarCardRowView, card.row?.workingStartedMs != nil else { continue }
            card.nowMs = nowMs
            card.refresh()
        }
    }

    // MARK: Motion (Sidebar.motion.ts: 150ms ease-out, transform and opacity only)

    func slide(_ view: NSView, from offset: CGFloat) {
        guard let layer = view.layer else { return }
        let a = CABasicAnimation(keyPath: "transform.translation.y")
        a.fromValue = offset
        a.toValue = 0
        a.isAdditive = true
        a.duration = Self.duration
        a.timingFunction = Self.easing
        layer.add(a, forKey: "slide")
    }

    /// Entering rows rise in from `-min(height, 40)` while fading in.
    private func fadeIn(_ view: NSView) {
        guard let layer = view.layer else { return }
        let travel = -min(view.frame.height, 40)
        let move = CABasicAnimation(keyPath: "transform.translation.y")
        move.fromValue = travel; move.toValue = 0; move.isAdditive = true
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0; fade.toValue = 1
        let group = CAAnimationGroup()
        group.animations = [move, fade]
        group.duration = Self.duration
        group.timingFunction = Self.easing
        layer.add(group, forKey: "enter")
    }

    /// Leaving rows keep their place and fade out moving `min(height, 40)` down, then return to the pool.
    private func fadeOut(_ view: SidebarRowBase) {
        guard let layer = view.layer else { recycle(view); return }
        let id = ObjectIdentifier(view)
        exiting.insert(id)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak view] in
            MainActor.assumeIsolated {
                guard let self, let view else { return }
                self.exiting.remove(id)
                view.alphaValue = 1
                self.recycle(view)
            }
        }
        let move = CABasicAnimation(keyPath: "transform.translation.y")
        move.fromValue = 0; move.toValue = min(view.frame.height, 40); move.isAdditive = true
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1; fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [move, fade]
        group.duration = Self.duration
        group.timingFunction = Self.easing
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        layer.add(group, forKey: "exit")
        CATransaction.commit()
    }

    // MARK: Keyboard (T3 rows are buttons: Tab and arrows move focus, Enter or Space opens)

    public override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125: moveFocus(1)       // down
        case 126: moveFocus(-1)      // up
        case 115: focus(index: 0)    // home
        case 119: focus(index: items.count - 1) // end
        case 36, 76, 49:             // return, enter, space
            if let key = focusedKey, let i = indexByKey[key] { open(items[i]) }
        default: super.keyDown(with: event)
        }
    }

    public override func becomeFirstResponder() -> Bool {
        // A click on the list's padding or a gap between rows lands on a plain div in T3 and focuses nothing.
        // Taking focus here put the active row in keyboard focus, which swaps its status (Working, Done) for
        // the Settle actions until focus left (Sidebar.tsx:2019-2027 hides the label only on focus-visible).
        if let type = window?.currentEvent?.type, [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(type) { return false }
        // T3's rows are plain buttons with no roving focus: Tab lands on the first one in DOM order and
        // Shift-Tab on the last, whichever row is active.
        if focusedKey == nil, !items.isEmpty {
            let event = window?.currentEvent
            moveFocus(event?.type == .keyDown && event?.modifierFlags.contains(.shift) == true ? -1 : 1)
        }
        return true
    }

    public override func resignFirstResponder() -> Bool {
        setFocusedKey(nil)
        return true
    }

    func moveFocus(_ delta: Int) {
        guard !items.isEmpty else { return }
        var i = focusedKey.flatMap { indexByKey[$0] } ?? (delta > 0 ? -1 : items.count)
        repeat { i += delta } while items.indices.contains(i) && !items[i].isFocusable
        if items.indices.contains(i) { focus(index: i) }
    }

    func focus(index: Int) {
        guard items.indices.contains(index), items[index].isFocusable else { return }
        setFocusedKey(items[index].key)
        scrollToVisible(frame(at: index).insetBy(dx: 0, dy: -4))
        tile(oldTops: nil)
    }

    private func setFocusedKey(_ key: String?) {
        if let old = focusedKey { visible[old]?.isKeyboardFocused = false }
        focusedKey = key
        if let key { visible[key]?.isKeyboardFocused = true }
    }

    private func open(_ item: SidebarItem) {
        switch item {
        case .row(let r): onOpen?(r.id)
        case .shelfHeader(let shelf, _, _): onToggleShelf?(shelf)
        case .showMore: onShowMore?()
        case .draft(let d): onOpenDraft?(d.id)
        case .searchResult(let r): onOpenSearchResult?(r.id)
        case .noProjects: onAddProject?()
        case .draftDivider, .emptyText: break
        }
    }

    /// The frame of the item with this key, for scrolling a search highlight into view.
    func scrollItemToVisible(_ key: String) {
        guard let i = indexByKey[key] else { return }
        scrollToVisible(frame(at: i))
        tile(oldTops: nil)
    }

    /// The row view for a key if it is laid out (tests, previews).
    func view(forKey key: String) -> SidebarRowBase? { visible[key] }
    var poolSizes: [SidebarItem.Kind: Int] { pools.mapValues(\.count) }
    var liveViewCount: Int { visible.count }
    /// The live view for an item key, for tests.
    func rowView(_ key: String) -> SidebarRowBase? { visible[key] }
}
