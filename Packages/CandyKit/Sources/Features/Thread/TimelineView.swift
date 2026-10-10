import AppKit
import DesignSystem
import T3Protocol
import T3Store

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

    enum Kind: Hashable { case user, assistant, meta, plan, work, toggle, live, thinking, working, turnFold, attemptFold, compaction, event }

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

    /// Space above the first row: the `topbar-scroll-fade` spacer (1.5rem).
    public var topInset: CGFloat = 24 { didSet { if topInset != oldValue { relayout() } } }
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
    }

    isolated deinit {
        if let clipObserver { NotificationCenter.default.removeObserver(clipObserver) }
    }

    // MARK: Data

    /// Replaces the rows. Unchanged rows keep their views and heights.
    func setItems(_ new: [TimelineItem]) {
        let anchor = captureAnchor()
        items = new
        indexById = Dictionary(new.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        // Drop measurements of rows that left.
        if measured.count > new.count * 2 { measured = measured.filter { indexById[$0.key] != nil } }
        heights = new.map { height(of: $0) }
        recomputeTops()
        restore(anchor)
        tile()
    }

    // MARK: Geometry

    /// `resolveChatCanvasLayout` without previews (chatCanvasLayout.ts:26-60): 48px padding (12px
    /// below 640px), the lane at most 736px wide, centered.
    var laneFrame: (x: CGFloat, width: CGFloat) {
        let w = document.bounds.width
        let padding: CGFloat = w >= 640 ? 48 : 12
        let lane = max(0, min(Self.maxLane, w - padding * 2))
        return (((w - lane) / 2), lane)
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
        case .message(let m, _, let meta, _, _, _):
            if m.role == .user { return min(176, lines(m.text, 7.5 / 0.8) * 22.75) + 24 + 44 }
            return lines(m.text, 7.5) * 22.75 + 4 + (meta ? 46 : 8)
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
        }
    }

    private func recomputeTops() {
        tops = []
        tops.reserveCapacity(items.count)
        var y = topInset
        for h in heights {
            tops.append(y)
            y += h
        }
        let height = y + Self.footer + bottomInset
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
        let lane = laneFrame
        var wanted = range(viewport.insetBy(dx: 0, dy: -Self.overscan))
        for _ in 0..<4 {
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
        for i in wanted {
            let view = viewFor(i)
            let frame = NSRect(x: TL.snap(lane.x), y: TL.snap(tops[i]), width: lane.width, height: heights[i])
            if view.frame != frame || relayoutAll { view.frame = frame; view.needsLayout = true }
        }
    }

    private func viewFor(_ i: Int) -> TimelineRowView {
        let item = items[i]
        if let view = visible[item.id] {
            if view.item != item { configureCount += 1; view.configure(item) }
            return view
        }
        let view = dequeue(Self.kind(item.row))
        configureCount += 1
        view.configure(item)
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
        case .event: .event
        }
    }

    private func dequeue(_ kind: Kind) -> TimelineRowView {
        if let view = pools[kind]?.popLast() {
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
        }
        view.context = context
        document.addSubview(view)
        return view
    }

    private func recycle(_ view: TimelineRowView) {
        view.isHidden = true
        view.prepareForReuse()
        if let item = view.item { pools[Self.kind(item.row), default: []].append(view) }
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
            let view = visible[item.id] ?? dequeue(Self.kind(item.row))
            if view.item != item { configureCount += 1; view.configure(item) }
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

    // MARK: Test hooks

    func view(forRow id: String) -> TimelineRowView? { visible[id] }
    var liveViewCount: Int { visible.count }
    var isPillVisible: Bool { !pill.isHidden }
    var documentHeight: CGFloat { contentHeight }
}
