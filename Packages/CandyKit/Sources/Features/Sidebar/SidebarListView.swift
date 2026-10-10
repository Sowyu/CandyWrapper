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
    private var tops: [CGFloat] = []
    private var indexByKey: [String: Int] = [:]
    private var visible: [String: SidebarRowBase] = [:]
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
    /// The pointer moved over a search result (`onMouseMove` highlights it).
    var onHighlightSearchResult: (@MainActor (Int) -> Void)?
    var rowActions = SidebarRowActions()
    var onVisibleRowsChange: (@MainActor () -> Void)?

    /// Counters for tests: how many row views were made and how many configure calls ran.
    public private(set) var createdRowViews = 0
    public private(set) var configureCount = 0

    public override var acceptsFirstResponder: Bool { true }
    public override var canBecomeKeyView: Bool { true }

    // MARK: Data

    /// Replaces the items. Rows whose model is unchanged keep their view untouched; moved rows slide.
    public func setItems(_ new: [SidebarItem], animated: Bool) {
        let oldTops = Dictionary(uniqueKeysWithValues: items.indices.map { (items[$0].key, tops[$0]) })
        let oldVisible = visible
        let oldItems = Dictionary(uniqueKeysWithValues: items.map { ($0.key, $0) })
        items = new
        recomputeGeometry()
        let shouldAnimate = animated && window != nil && !Motion.reduced && !oldTops.isEmpty
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
        // Changed rows that stay visible get the new model; nothing else is touched.
        for (key, view) in visible {
            guard let i = indexByKey[key] else { continue }
            if oldItems[key] != items[i] || view.item != items[i] { configure(view, items[i]) }
        }
        tile(oldTops: shouldAnimate ? oldTops : nil)
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

    private func frame(at i: Int) -> NSRect {
        NSRect(x: Self.padding, y: tops[i], width: max(0, bounds.width - Self.padding * 2), height: items[i].height)
    }

    private func tile(oldTops: [String: CGFloat]?, relayoutAll: Bool = false) {
        let range = visibleRange
        let wanted = Set(range.map { items[$0].key })
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
                if let oldTops, oldTops[item.key] == nil, entering < Self.maxFadedRows {
                    entering += 1
                    fadeIn(view)
                }
            }
        }
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
        }
        view.onOpen = { [weak self, weak view] in
            guard let self, let item = view?.item else { return }
            self.open(item)
        }
        addSubview(view)
        return view
    }

    private func recycle(_ view: SidebarRowBase) {
        view.layer?.removeAllAnimations()
        view.isHidden = true
        view.isKeyboardFocused = false
        if let kind = view.item?.kind { pools[kind, default: []].append(view) }
    }

    private func configure(_ view: SidebarRowBase, _ item: SidebarItem) {
        configureCount += 1
        if let card = view as? SidebarCardRowView { card.actions = rowActions; card.nowMs = nowMs }
        if let slim = view as? SidebarSlimRowView { slim.actions = rowActions }
        view.configure(item)
        view.isKeyboardFocused = item.key == focusedKey
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

    private func slide(_ view: NSView, from offset: CGFloat) {
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
        if focusedKey == nil, !items.isEmpty {
            let start = items.firstIndex { if case .row(let r) = $0 { r.isActive } else { false } } ?? 0
            focus(index: start)
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
}
