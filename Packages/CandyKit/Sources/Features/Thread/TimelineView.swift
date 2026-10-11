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
}

/// The messages timeline (MessagesTimeline.tsx): a virtualized list in T3's centered chat lane.
///
/// Only rows inside the visible rect plus `overscan` have views, recycled per kind. Each row's
/// measured height is cached by id, width and content; rows never measured use an estimate. When
/// heights or rows above the viewport change, the first visible row keeps its place on screen.
/// While the viewport touches the end, it follows the end as content grows (`maintainScrollAtEnd`).
public final class TimelineView: DSView {
    static let overscan: CGFloat = 400
    /// `--chat-content-max-width` at the default `comfortable` chat width.
    static let maxLane: CGFloat = 736
    /// The list footer under the last row (`h-3 sm:h-4`).
    static let footer: CGFloat = 16
    /// Distance from the top that asks for older history.
    static let nearTop: CGFloat = 600

    enum Kind: Hashable { case user, assistant, meta, plan, work, toggle, live, thinking, working, turnFold, attemptFold, compaction, event, secret, htmlRender, mcpApp }

    let context = TimelineContext()
    let scrollView = NSScrollView()
    private let document = DSView()
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
    private var laidOutWidth: CGFloat = 0
    private var tiling = false
    private var retile = false
    public var threadFindQuery = "" {
        didSet { if threadFindQuery != oldValue { visible.values.forEach(applyFindHighlight) } }
    }
    private func applyFindHighlight(_ view: NSView) {
        if let markdown = view as? MarkdownView { markdown.threadFindQuery = threadFindQuery }
        view.subviews.forEach(applyFindHighlight)
    }


    /// Space above the first row: the `topbar-scroll-fade` spacer (1.5rem), under the header view if any.
    public var topInset: CGFloat = 24 { didSet { if topInset != oldValue { relayout() } } }
    /// A view above the rows in the lane (the list header's "Subagent of" divider, MessagesTimeline.tsx:1409-1437),
    /// `headerHeight` tall, before the 24pt spacer.
    public func setHeader(_ view: NSView?, height: CGFloat) {
        if header !== view {
            header?.removeFromSuperview()
            header = view
            if let view { document.addSubview(view) }
        }
        headerHeight = view == nil ? 0 : height
        topInset = 24 + headerHeight
        layoutHeader()
    }
    private var header: NSView?
    private var headerHeight: CGFloat = 0
    /// A view after the last row (the list footer: `ThreadStatusLine`, ChatView.tsx:7613-7646, 11410).
    public func setFooter(_ view: NSView?, height: CGFloat) {
        if footerView !== view {
            footerView?.removeFromSuperview()
            footerView = view
            if let view { document.addSubview(view) }
        }
        let h = view == nil ? 0 : height
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
        header?.frame = NSRect(x: TL.snap(lane.x), y: 0, width: lane.width, height: headerHeight)
    }
    /// Space the floating composer covers at the bottom. The last row scrolls clear of it.
    public var bottomInset: CGFloat = 0 { didSet { if bottomInset != oldValue { relayout(); needsLayout = true } } }
    /// True while the viewport is at the end; new content then keeps it there.
    public private(set) var followsEnd = true
    /// The user scrolled within `nearTop` of the first row. Called once per first row, so the
    /// app can load an older page and prepend it; the visible rows stay where they are.
    public var onNearTop: (@MainActor () -> Void)?

    /// Counters for tests.
    private(set) var createdRowViews = 0
    private(set) var configureCount = 0

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.verticalScrollElasticity = .allowed
        scrollView.documentView = document
        addSubview(scrollView)
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
        }
        // A Mermaid diagram finished or toggled: the messages with diagrams measure again (their Markdown views
        // drop their own layouts first, so this waits a turn of the run loop).
        diagramObserver = NotificationCenter.default.addObserver(forName: MermaidDiagrams.didRender, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.remeasureDiagrams() } }
        }
    }

    private var diagramObserver: NSObjectProtocol?

    private func remeasureDiagrams() {
        var changed = false
        for item in items {
            guard let text = item.row.message?.text, text.contains("mermaid"), measured.removeValue(forKey: item.id) != nil else { continue }
            changed = true
        }
        guard changed else { return }
        for view in visible.values { if let item = view.item, item.row.message?.text.contains("mermaid") == true { view.configure(item); applyFindHighlight(view); view.needsLayout = true } }
        heights = items.map { height(of: $0) }
        relayout()
    }

    /// Configures the visible rows again with the same items.
    private func reconfigureVisible() {
        for view in visible.values { if let item = view.item { view.configure(item); applyFindHighlight(view) } }
    }

    isolated deinit {
        if let clipObserver { NotificationCenter.default.removeObserver(clipObserver) }
    }

    // MARK: Data

    /// Replaces the rows. Unchanged rows keep their views and heights. `change` says which rows
    /// differ from the current ones, so an update on a long thread touches only those.
    func setItems(_ new: [TimelineItem], change: TimelineChange = .all) {
        let anchor = captureAnchor()
        let old = items
        items = new
        let consistent = heights.count == old.count && tops.count == old.count
        if case .rows(let changed) = change, consistent, new.count == old.count {
            var first = new.count
            for i in changed {
                let h = height(of: new[i])
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
        if OpenTiming.active, !new.isEmpty { markFirstFrame() }
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

    /// Jump to a server search entry already present in the window of history.
    @discardableResult
    public func revealFindEntry(_ entryId: String) -> Bool {
        guard let i = indexById[entryId], i < tops.count else { return false }
        followsEnd = false
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, min(maxScroll, tops[i] - 60))))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        tile()
        return true
    }

    // MARK: Geometry

    /// `resolveChatCanvasLayout` without previews (chatCanvasLayout.ts:26-60): 48px padding (12px
    /// below 640px), the lane at most 736px wide, centered.
    var laneFrame: (x: CGFloat, width: CGFloat) {
        let w = document.bounds.width
        // `px-3 sm:px-12`: the breakpoint is the viewport's width, not the column's, so the lane
        // keeps 48px beside an open right panel.
        let padding: CGFloat = viewportWidth >= 640 ? 48 : 12
        let lane = max(0, min(ThreadChatWidth.maximum(ClientSettingsStore.shared.current.string("chatWidth")), w - padding * 2))
        return (((w - lane) / 2), lane)
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
            return lines(m.text, 7.5) * 22.75 + 4 + card + (meta ? 46 : 8)
        case .assistantMeta: return 42
        case .proposedPlan(let p): return min(416, lines(p.planMarkdown, 7.5) * 22.75) + 140
        case .work(let entries, let group, _): return CGFloat(entries.count) * (group ? 24 : 28) + (group ? 4 : 8)
        case .workToggle, .thinking: return 36
        case .workLive: return 36
        case .working: return 43
        case .turnFold: return 41.75
        case .attemptFold: return 42
        case .contextCompaction: return 40
        case .event: return 48
        case .htmlRender(let page): return CGFloat(page.frameHeight(width: Double(max(0, width - 8)), contentHeight: item.ui.webContentHeight)) + 8
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

    private struct Anchor { var id: String; var offset: CGFloat }

    private func captureAnchor() -> Anchor? {
        guard !followsEnd, !items.isEmpty, tops.count == items.count else { return nil }
        let i = min(lowerBound(viewport.minY), items.count - 1)
        return Anchor(id: items[i].id, offset: tops[i] - viewport.minY)
    }

    private func restore(_ anchor: Anchor?) {
        if followsEnd {
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
    }

    // MARK: Layout and tiling

    public override func layout() {
        OpenTiming.measure("timeline layout", "\(items.count) rows") { layoutNow() }
    }

    private func layoutNow() {
        super.layout()
        scrollView.frame = bounds
        let width = scrollView.contentSize.width
        if width != laidOutWidth || document.frame.width != width {
            let anchor = captureAnchor()
            laidOutWidth = width
            adjusting = true
            document.setFrameSize(NSSize(width: width, height: document.frame.height))
            adjusting = false
            heights = items.map { height(of: $0) }
            recomputeTops()
            restore(anchor)
        }
        tile(relayoutAll: true)
        layoutPill()
        layoutHeader()
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
        if viewport.minY < Self.nearTop, let first = items.first?.id, first != lastNearTopId, onNearTop != nil {
            lastNearTopId = first
            onNearTop?()
        }
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
            if view.frame != frame || relayoutAll { view.frame = frame; view.needsLayout = true }
        }
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
        case .message(let m, _, _, _, _, _): m.role == .user ? .user : .assistant
        case .assistantMeta: .meta
        case .proposedPlan: .plan
        case .work: .work
        case .workToggle: .toggle
        case .workLive: .live
        case .thinking: .thinking
        case .working: .working
        case .turnFold: .turnFold
        case .attemptFold: .attemptFold
        case .contextCompaction: .compaction
        case .event(let p, _, _): p.item.type == .secretRequest ? .secret : .event
        case .htmlRender: .htmlRender
        case .mcpApp: .mcpApp
        }
    }

    private func dequeue(_ kind: Kind) -> TimelineRowView {
        if let view = pools[kind]?.popLast() {
            view.pooled = false
            view.isHidden = false
            return view
        }
        createdRowViews += 1
        let view: TimelineRowView = switch kind {
        case .user: UserMessageRowView()
        case .assistant: AssistantMessageRowView()
        case .meta: AssistantMetaRowView()
        case .plan: PlanRowView()
        case .work: WorkRowView()
        case .toggle: WorkToggleRowView()
        case .live: WorkLiveRowView()
        case .thinking: ThinkingRowView()
        case .working: WorkingRowView()
        case .turnFold: TurnFoldRowView()
        case .attemptFold: AttemptFoldRowView()
        case .compaction: CompactionRowView()
        case .event: EventRowView()
        case .secret: SecretRequestRowView()
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
