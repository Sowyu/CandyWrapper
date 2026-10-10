import AppKit
import DesignSystem

/// The diff body: every file's header and, for expanded files, its hunks, in one virtualized
/// column like T3's `CodeView`. Only rows inside the clip view plus `overscan` have views, recycled
/// per kind; a 20,000-line diff keeps the same few dozen views. The current file's header sticks
/// to the top while its body scrolls (`stickyHeaders: true`).
public final class DiffListView: DSView {
    static let overscan: CGFloat = 200

    public private(set) var diff = UnifiedDiff("")
    public private(set) var collapsed: Set<Int> = []
    public var style: DiffViewStyle = .unified { didSet { if style != oldValue { relayout() } } }
    public var wrap = true { didSet { if wrap != oldValue { scrollX = 0; relayout() } } }
    public var statStyle: DiffStatStyle = .pierre { didSet { if statStyle != oldValue { reconfigureAll() } } }
    /// Called with a file path when its name is clicked (T3 opens it in the editor). Unset: the
    /// name toggles the file like the rest of the header.
    public var onOpenFile: (@MainActor (String) -> Void)?
    var onCollapsedChange: (@MainActor () -> Void)?
    /// The pull request Code tab's viewed marks by path; nil hides the tick.
    public var viewedState: (@MainActor (String) -> (viewed: Bool, stale: Bool)?)? { didSet { reconfigureAll() } }
    /// A tick pressed: viewing a file folds it, clearing the tick opens it (`toggleFileDiffFoldForViewed`).
    public var onSetViewed: (@MainActor (String, Bool) -> Void)?

    private(set) var rowLayout = DiffLayout(diff: UnifiedDiff(""), collapsed: [], style: .unified, width: 0, wrap: true, ch: 7.8)
    private var highlighter = DiffHighlighter(diff: UnifiedDiff(""))
    private var visible: [Int: DiffRowView] = [:]
    private var pools: [DiffLayout.Row.Kind: [DiffRowView]] = [:]
    private var clipObserver: NSObjectProtocol?
    /// Shared horizontal offset of code text when lines do not wrap.
    // ponytail: one offset for the whole list instead of pierre's per-file scrollers; fine while
    // files are read one at a time. Give each file its own offset if users compare across files.
    private var scrollX: CGFloat = 0
    private var maxScrollX: CGFloat = 0

    /// Counters for tests.
    public private(set) var createdRowViews = 0
    public var liveRowViews: Int { visible.count }

    public override var acceptsFirstResponder: Bool { true }

    // MARK: Data

    /// Shows a parsed diff with every file collapsed or expanded (T3's `diffFilesCollapsed`
    /// setting, default true).
    public func setDiff(_ diff: UnifiedDiff, collapsedByDefault: Bool = true) {
        self.diff = diff
        collapsed = collapsedByDefault ? Set(diff.files.indices) : []
        highlighter = DiffHighlighter(diff: diff)
        for view in visible.values { recycle(view) }
        visible = [:]
        scrollX = 0
        relayout()
    }

    public func setCollapsed(_ file: Int, _ value: Bool) {
        guard diff.files.indices.contains(file), collapsed.contains(file) != value else { return }
        if value { collapsed.insert(file) } else { collapsed.remove(file) }
        relayoutKeepingAnchor()
        onCollapsedChange?()
    }

    public func toggle(_ file: Int) { setCollapsed(file, !collapsed.contains(file)) }

    public var allCollapsed: Bool { !diff.files.isEmpty && collapsed.count == diff.files.count }

    public func setAllCollapsed(_ value: Bool) {
        collapsed = value ? Set(diff.files.indices) : []
        relayoutKeepingAnchor()
        onCollapsedChange?()
    }

    /// Expands `path` and scrolls its header to the top (T3's reveal of the file picked in the
    /// changed files card).
    /// Scrolls `path`'s header to the top; `expand` also opens it (T3's lazy git sources do, turn
    /// diffs only scroll, DiffPanel.tsx:595-650).
    public func reveal(path: String, expand: Bool = true) {
        guard let file = diff.files.firstIndex(where: { $0.path == path }) else { return }
        if expand, collapsed.contains(file) { collapsed.remove(file); relayout(); onCollapsedChange?() }
        layoutSubtreeIfNeeded()
        let y = rowLayout.rows[rowLayout.headerRow[file]].top
        scrollTo(NSPoint(x: 0, y: min(y, max(0, frame.height - viewportHeight))))
    }

    // MARK: Geometry

    private var viewportHeight: CGFloat { enclosingScrollView?.contentView.bounds.height ?? bounds.height }

    private func relayout() {
        let width = enclosingScrollView?.contentView.bounds.width ?? bounds.width
        rowLayout = DiffLayout(diff: diff, collapsed: collapsed, style: style, width: width, wrap: wrap, ch: DiffStyle.ch)
        maxScrollX = wrap ? 0 : longestLineWidth(width: width)
        let height = max(rowLayout.height, viewportHeight)
        if frame.size != NSSize(width: width, height: height) { setFrameSize(NSSize(width: width, height: height)) }
        reconfigureAll()
    }

    /// Keeps the first visible row's file header in place when a file above it folds.
    private func relayoutKeepingAnchor() {
        let top = visibleRect.minY
        let anchorFile = rowLayout.rows.isEmpty ? -1 : Int(rowLayout.rows[rowLayout.rowIndex(at: top)].file)
        let offset = anchorFile >= 0 ? top - rowLayout.rows[rowLayout.headerRow[anchorFile]].top : 0
        relayout()
        if anchorFile >= 0 {
            let y = rowLayout.rows[rowLayout.headerRow[anchorFile]].top + min(offset, 0)
            if y < visibleRect.minY { scrollTo(NSPoint(x: 0, y: y)) }
        }
    }

    private func longestLineWidth(width: CGFloat) -> CGFloat {
        var longest: Int32 = 0
        for f in diff.files.indices where !collapsed.contains(f) {
            for hunk in diff.files[f].hunks { for i in hunk.lines { longest = max(longest, diff.lines[i].length) } }
        }
        let code = rowLayout.columns.first.map { $0.codeWidth.min() ?? width } ?? width
        return max(0, CGFloat(longest) * DiffStyle.ch + 2 * DiffStyle.ch - code)
    }

    public override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if let clipObserver { NotificationCenter.default.removeObserver(clipObserver) }
        guard let clip = superview as? NSClipView else { return }
        clip.postsBoundsChangedNotifications = true
        clip.postsFrameChangedNotifications = true
        clipObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tile() }
        }
    }

    /// Width follows the clip view; a change re-wraps every line.
    public override func layout() {
        super.layout()
        let width = enclosingScrollView?.contentView.bounds.width ?? bounds.width
        if width != rowLayout.width || frame.height < viewportHeight { relayout() } else { tile() }
    }

    // MARK: Tiling

    private func reconfigureAll() {
        for (index, view) in visible { recycle(view); visible[index] = nil }
        tile()
    }

    private var context: DiffRowContext {
        DiffRowContext(diff: diff, layout: rowLayout, highlighter: highlighter, scrollX: scrollX)
    }

    func tile() {
        let rows = rowLayout.rows
        guard !rows.isEmpty else {
            for view in visible.values { recycle(view) }
            visible = [:]
            return
        }
        let rect = visibleRect
        let lo = rowLayout.rowIndex(at: max(0, rect.minY - Self.overscan))
        var hi = lo
        while hi < rows.count, rows[hi].top < rect.maxY + Self.overscan { hi += 1 }
        // The sticky header: the header of the expanded file whose body crosses the top edge.
        let topRow = rows[rowLayout.rowIndex(at: rect.minY)]
        let file = Int(topRow.file)
        let sticky = !collapsed.contains(file) && topRow.kind != .header ? rowLayout.headerRow[file] : -1
        var wanted = Set(lo..<hi)
        wanted = wanted.filter { rows[$0].kind != .footer }
        if sticky >= 0 { wanted.insert(sticky) }
        for (index, view) in visible where !wanted.contains(index) {
            visible[index] = nil
            recycle(view)
        }
        let context = self.context
        for index in wanted {
            let row = rows[index]
            var frame = NSRect(x: 0, y: row.top, width: bounds.width, height: rowLayout.bottom(of: index) - row.top)
            if index == sticky || (row.kind == .header && index == rowLayout.headerRow[file] && !collapsed.contains(file)) {
                // Pinned at the top until the file's end pushes it up.
                let fileEnd = Int(row.file) + 1 < rowLayout.headerRow.count ? rows[rowLayout.headerRow[Int(row.file) + 1]].top : rowLayout.height
                frame.origin.y = max(row.top, min(rect.minY, fileEnd - DiffStyle.fileBottomPadding - DiffStyle.headerHeight))
            }
            if let view = visible[index] {
                if view.frame != frame { view.frame = frame }
            } else {
                let view = dequeue(row.kind)
                view.frame = frame
                configure(view, row, index: index, context)
                visible[index] = view
            }
            visible[index]?.layer?.zPosition = row.kind == .header ? 2 : 0
        }
    }

    private func configure(_ view: DiffRowView, _ row: DiffLayout.Row, index: Int, _ context: DiffRowContext) {
        view.rowIndex = index
        switch view {
        case let header as DiffFileHeaderView:
            let f = Int(row.file)
            header.configure(file: f, diff.files[f], collapsed: collapsed.contains(f), statStyle: statStyle)
            header.configure(viewed: viewedState?(diff.files[f].path))
        case let separator as DiffSeparatorView:
            separator.configure(hidden: Int(row.right), split: rowLayout.columns[Int(row.file)].isSplit)
        case let line as DiffLineRowView:
            line.configure(row: row, context)
        default: break
        }
    }

    private func dequeue(_ kind: DiffLayout.Row.Kind) -> DiffRowView {
        let poolKind: DiffLayout.Row.Kind = kind == .noNewline ? .line : kind
        if let view = pools[poolKind]?.popLast() {
            view.isHidden = false
            return view
        }
        createdRowViews += 1
        let view: DiffRowView
        switch poolKind {
        case .header:
            let header = DiffFileHeaderView()
            header.onToggle = { [weak self] in self?.toggle($0) }
            header.onOpenFile = { [weak self] path in self?.onOpenFile?(path) ?? self?.togglePath(path) }
            header.onViewed = { [weak self] path, viewed in
                guard let self else { return }
                self.onSetViewed?(path, viewed)
                if let f = self.diff.files.firstIndex(where: { $0.path == path }) { self.setCollapsed(f, viewed) }
            }
            view = header
        case .separator: view = DiffSeparatorView()
        default: view = DiffLineRowView()
        }
        addSubview(view)
        return view
    }

    private func togglePath(_ path: String) {
        if let f = diff.files.firstIndex(where: { $0.path == path }) { toggle(f) }
    }

    private func recycle(_ view: DiffRowView) {
        view.isHidden = true
        let kind: DiffLayout.Row.Kind = view is DiffFileHeaderView ? .header : view is DiffSeparatorView ? .separator : .line
        pools[kind, default: []].append(view)
    }

    private func scrollTo(_ point: NSPoint) {
        guard let clip = enclosingScrollView?.contentView else { return }
        clip.scroll(to: point)
        enclosingScrollView?.reflectScrolledClipView(clip)
    }

    /// Horizontal wheel deltas scroll unwrapped code; vertical ones go to the scroll view.
    public override func scrollWheel(with event: NSEvent) {
        if !wrap, abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
            let next = min(maxScrollX, max(0, scrollX - event.scrollingDeltaX))
            if next != scrollX { scrollX = next; reconfigureAll() }
            return
        }
        super.scrollWheel(with: event)
    }

    public override func updateLayer() {
        layer?.backgroundColor = DiffStyle.surface.cgColor(in: self)
    }
}
