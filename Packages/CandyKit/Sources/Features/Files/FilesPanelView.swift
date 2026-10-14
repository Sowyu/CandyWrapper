import AppKit
import DesignSystem

/// The Files surface (FileBrowserPanel.tsx): a subheader with refresh, the path search and expand
/// all, then the project tree. In the right panel's inline mode the subheader is 36px with 4px
/// below and no border (`in-data-[preview-panel-mode=inline]:h-9 mb-1 border-b-transparent`).
/// The owner feeds folder listings into `tree` and answers `onLoad`, `onSearch` and `onOpenFile`.
public final class FilesPanelView: DSView {
    public let treeView = FileTreeView()
    public let refresh = ButtonView(nil, icon: .refreshCw, variant: .ghost, size: .iconXs)
    public let searchField = InputGroupView(placeholder: "Search files", variant: .ghost)
    public let expandAll = ButtonView(nil, icon: .chevronsUpDown, variant: .ghost, size: .iconXs)
    private let status = LabelView("", font: DSFont.ui(12))
    private let errorButton = LabelView("", font: DSFont.ui(12))
    private let scroll: ScrollAreaView
    private let border = CALayer()

    /// Folders to list (`projects.listEntries` with `directoryPath`).
    public var onLoad: (@MainActor ([String]) -> Void)?
    /// The search text changed; the owner runs `projects.searchEntries` and calls `setSearchResults`.
    public var onSearch: (@MainActor (String) -> Void)?
    /// A file row was clicked.
    public var onOpenFile: (@MainActor (String) -> Void)? {
        get { treeView.onOpenFile }
        set { treeView.onOpenFile = newValue }
    }
    /// Refresh: reload every listed folder.
    public var onRefresh: (@MainActor () -> Void)?
    /// The inline subheader (the right panel's tab mode); off draws T3's 40px bordered row.
    public var inline = true { didSet { needsLayout = true } }

    public var model: FileTreeModel {
        get { treeView.model }
        set { treeView.model = newValue; updateChrome() }
    }

    /// "Loading files…", the error line and "More matches available. Refine your search."
    public var isLoading = false { didSet { updateChrome() } }
    public var errorText: String? { didSet { updateChrome() } }
    public var searchTruncated = false { didSet { updateChrome() } }
    public var searchPending = false { didSet { updateChrome() } }

    public override init(frame frameRect: NSRect) {
        scroll = ScrollAreaView(documentView: treeView)
        super.init(frame: frameRect)
        refresh.iconSize = 14
        refresh.setAccessibilityLabel("Refresh workspace files")
        refresh.toolTip = "Refresh files"
        refresh.action = { [weak self] in self?.onRefresh?() }
        expandAll.iconSize = 14
        expandAll.action = { [weak self] in self?.toggleAll() }
        searchField.input.size = .sm
        searchField.input.onChange = { [weak self] text in self?.searchChanged(text) }
        searchField.input.onCommand = { [weak self] selector in
            guard selector == #selector(NSResponder.cancelOperation(_:)), let self else { return false }
            searchField.input.text = ""
            searchChanged("")
            window?.makeFirstResponder(nil)
            return true
        }
        status.text = "Loading files\u{2026}"
        status.lineHeight = 16
        errorButton.lineHeight = 19.5
        border.actions = ["frame": NSNull(), "hidden": NSNull()]
        layer?.addSublayer(border)
        [scroll, refresh, searchField, expandAll, status, errorButton].forEach(addSubview)
        treeView.onLoad = { [weak self] dirs in self?.onLoad?(dirs) }
        treeView.onModelChange = { [weak self] in self?.updateChrome() }
        updateChrome()
    }

    private func searchChanged(_ text: String) {
        if text.trimmingCharacters(in: .whitespaces).isEmpty { treeView.model.setSearch("", entries: nil) }
        onSearch?(text)
    }

    /// Results for `query` from `projects.searchEntries`.
    public func setSearchResults(_ entries: [ProjectEntry], query: String, truncated: Bool) {
        guard query == searchField.input.text else { return }
        treeView.model.setSearch(query, entries: entries)
        searchTruncated = truncated
        searchPending = false
    }

    private func toggleAll() {
        let expand = !treeView.model.allExpanded
        let need = treeView.model.setAllExpanded(expand)
        treeView.reload()
        if !need.isEmpty { onLoad?(need) }
    }

    private func updateChrome() {
        let all = treeView.model.allExpanded
        expandAll.icon = all ? .chevronsDownUp : .chevronsUpDown
        expandAll.iconSize = 14
        let label = all ? "Collapse all folders" : "Expand all folders"
        expandAll.setAccessibilityLabel(label)
        expandAll.toolTip = label
        expandAll.isHidden = treeView.model.directoryPaths.isEmpty
        let searching = !searchField.input.text.trimmingCharacters(in: .whitespaces).isEmpty
        if let errorText {
            errorButton.text = errorText + " Click to retry."
            errorButton.isHidden = false
        } else {
            errorButton.isHidden = true
        }
        if !treeView.model.ready || isLoading || searchPending {
            status.text = "Loading files\u{2026}"
            status.isHidden = false
        } else if searching && searchTruncated {
            status.text = "More matches available. Refine your search."
            status.isHidden = false
        } else {
            status.isHidden = true
        }
        needsLayout = true
        needsDisplay = true
    }

    public override func layout() {
        super.layout()
        let h: CGFloat = inline ? 36 : 40
        let w = bounds.width
        refresh.frame = NSRect(x: 8, y: (h - 24) / 2, width: 24, height: 24)
        var right = w - 8
        if !expandAll.isHidden {
            expandAll.frame = NSRect(x: right - 24, y: (h - 24) / 2, width: 24, height: 24)
            right -= 24 + 4
        }
        searchField.frame = NSRect(x: 36, y: (h - 28) / 2, width: max(0, right - 36), height: 28)
        border.frame = CGRect(x: 0, y: h - 1, width: w, height: 1)
        border.isHidden = inline
        var y = h + (inline ? 4 : 0)
        if !errorButton.isHidden {
            errorButton.frame = NSRect(x: 16, y: y + 16, width: max(0, w - 32), height: 19.5)
            y += 16 + 19.5 + 16
        }
        if !status.isHidden {
            status.frame = NSRect(x: 12, y: y + 4, width: max(0, w - 24), height: 16)
            y += 24
        }
        scroll.frame = NSRect(x: 0, y: y, width: w, height: max(0, bounds.height - y))
    }

    public override func updateLayer() {
        layer?.backgroundColor = WindowGlass.ground.cgColor(in: self)
        border.backgroundColor = Themed.color(\.border, 0.6).cgColor(in: self)
        status.color = Themed.color(\.mutedForeground)
        errorButton.color = Themed.color(\.destructive)
    }

    public override func mouseDown(with event: NSEvent) {
        if !errorButton.isHidden, errorButton.frame.contains(convert(event.locationInWindow, from: nil)) { onRefresh?() }
    }
}

/// The tree body: Pierre's compact rows (24px, 12px text, 16px icons), virtualized over the clip
/// view like the diff list. Folders show the chevron, files their type icon.
public final class FileTreeView: DSView {
    /// `compact` density: item height 24, factor 0.8 (`Je` in the trees bundle).
    static let rowHeight: CGFloat = 24
    static let factor: CGFloat = 0.8
    static let paddingX = 8 * factor, marginX = 2 * factor, rowGap = 6 * factor, levelGap = 8 * factor
    /// `padding-inline: max(16px - margin, 0)` on the scroll root.
    static let inset: CGFloat = 16 - marginX

    public var changes: [String: UnifiedDiff.Change] = [:] { didSet { reconfigureAll() } }
    public var model = FileTreeModel() { didSet { reload() } }
    var onLoad: (@MainActor ([String]) -> Void)?
    var onOpenFile: (@MainActor (String) -> Void)?
    var onModelChange: (@MainActor () -> Void)?
    /// The open file, drawn selected (`selectedPath`).
    public var selectedPath: String? { didSet { if selectedPath != oldValue { reconfigureAll() } } }
    /// Drags a file row into the composer as a mention (fileTreeDragMention.ts).
    public var onContextMenu: ((String, NSView, NSEvent) -> Void)?
    public var onDragPayload: ((String) -> String?)?

    private var rows: [FileTreeModel.Row] = []
    private var visible: [Int: FileTreeRowView] = [:]
    private var pool: [FileTreeRowView] = []
    private var clipObserver: NSObjectProtocol?
    private var hostHovered = false

    public override var isFlipped: Bool { true }

    public func reload() {
        rows = model.rows
        let width = enclosingScrollView?.contentView.bounds.width ?? bounds.width
        let height = max(CGFloat(rows.count) * Self.rowHeight + 8, enclosingScrollView?.contentView.bounds.height ?? 0)
        if frame.size != NSSize(width: width, height: height) { setFrameSize(NSSize(width: width, height: height)) }
        reconfigureAll()
        onModelChange?()
    }

    /// Scrolls `path`'s row to the middle (`scrollToPath(..., offset: "center")`).
    public func scrollToRow(_ path: String) {
        guard let index = rows.firstIndex(where: { $0.path == path }), let clip = enclosingScrollView?.contentView else { return }
        let target = CGFloat(index) * Self.rowHeight - (clip.bounds.height - Self.rowHeight) / 2
        clip.scroll(to: NSPoint(x: 0, y: max(0, min(target, frame.height - clip.bounds.height))))
        enclosingScrollView?.reflectScrolledClipView(clip)
    }

    public override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if let clipObserver { NotificationCenter.default.removeObserver(clipObserver) }
        guard let clip = superview as? NSClipView else { return }
        clip.postsBoundsChangedNotifications = true
        clipObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tile() }
        }
    }

    public override func layout() {
        super.layout()
        let width = enclosingScrollView?.contentView.bounds.width ?? bounds.width
        if width != frame.width { reload() } else { tile() }
    }

    private func reconfigureAll() {
        for (i, v) in visible { recycle(v); visible[i] = nil }
        tile()
    }

    func tile() {
        let rect = visibleRect.insetBy(dx: 0, dy: -100)
        let lo = max(0, Int(rect.minY / Self.rowHeight)), hi = min(rows.count, Int(ceil(rect.maxY / Self.rowHeight)))
        let wanted = lo < hi ? Set(lo..<hi) : []
        for (i, v) in visible where !wanted.contains(i) { visible[i] = nil; recycle(v) }
        for i in wanted.sorted() {
            let frame = NSRect(x: Self.inset + Self.marginX, y: CGFloat(i) * Self.rowHeight,
                               width: max(0, bounds.width - 2 * (Self.inset + Self.marginX)), height: Self.rowHeight)
            let view = visible[i] ?? dequeue()
            view.frame = frame
            view.change = changes[rows[i].path]
            view.configure(rows[i], selected: rows[i].path == selectedPath, guides: hostHovered)
            visible[i] = view
        }
    }

    private func dequeue() -> FileTreeRowView {
        if let v = pool.popLast() { v.isHidden = false; return v }
        let v = FileTreeRowView()
        v.onClick = { [weak self] row in self?.clicked(row) }
        v.onContextMenu = { [weak self] path, view, event in self?.onContextMenu?(path, view, event) }
        v.onDragPayload = { [weak self] path in self?.onDragPayload?(path) }
        addSubview(v)
        return v
    }

    private func recycle(_ v: FileTreeRowView) {
        v.prepareForReuse()
        v.isHidden = true
        pool.append(v)
    }

    private func clicked(_ row: FileTreeModel.Row) {
        if row.isDirectory {
            if model.search != nil, !(model.search?.query.isEmpty ?? true) { return }
            let need = model.toggle(row.path)
            if let need { model.loading.insert(need); onLoad?([need]) } else { reload() }
        } else {
            selectedPath = row.path
            onOpenFile?(row.path)
        }
    }

    private var tracking: NSTrackingArea?
    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }
    // `:host(:hover) [data-item-section="spacing-item"] { opacity: .75 }`
    public override func mouseEntered(with event: NSEvent) { hostHovered = true; for v in visible.values { v.guidesVisible = true } }
    public override func mouseExited(with event: NSEvent) { hostHovered = false; for v in visible.values { v.guidesVisible = false } }
}

/// One tree row (`button[data-type='item']`): `[spacing][icon][content]`, 5px radius, hover 7% and
/// selected 12% of the row's text color.
final class FileTreeRowView: DSView {
    private(set) var row = FileTreeModel.Row(path: "", label: "", depth: 0, isDirectory: false, isExpanded: false, ignored: false, isLoading: false, isSearchMatch: false)
    private let status = DiffChangeIconView(frame: .zero)
    var change: UnifiedDiff.Change? { didSet { status.change = change ?? .change; status.isHidden = change == nil; needsLayout = true } }
    private let label = LabelView("", font: DSFont.ui(12))
    private var icon = IconView(definition: FileTreeRowView.chevron, size: 16)
    private var guides: [CALayer] = []
    private var selected = false
    private var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }
    var guidesVisible = false { didSet { guides.forEach { $0.opacity = guidesVisible ? 0.75 : 0 } } }
    var onClick: ((FileTreeModel.Row) -> Void)?
    var onContextMenu: ((String, NSView, NSEvent) -> Void)?
    var onDragPayload: ((String) -> String?)?
    private var tracking: NSTrackingArea?
    private var downPoint: NSPoint?

    /// `file-tree-icon-chevron` from T3's sprite (pierre-icons.ts).
    static let chevron = IconDefinition(viewBox: IconViewBox(x: 0, y: 0, width: 16, height: 16), elements: [
        IconElement(.path(d: "M12.4697 5.46973C12.7626 5.17684 13.2374 5.17684 13.5303 5.46973C13.8232 5.76262 13.8232 6.23738 13.5303 6.53028L8.53028 11.5303C8.23738 11.8232 7.76262 11.8232 7.46973 11.5303L2.46973 6.53028C2.17684 6.23738 2.17684 5.76262 2.46973 5.46973C2.76262 5.17684 3.23738 5.17684 3.53028 5.46973L8 9.93946L12.4697 5.46973Z"),
                    IconPaint(fill: .current, opacity: 1, evenOdd: false)),
    ])

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.cornerRadius = 5
        label.lineHeight = 24
        addSubview(icon)
        addSubview(label)
    }

    /// `--trees-fg-muted`, the chevron's color.
    static let mutedFG = NSColor(srgbRed: 0x84 / 255.0, green: 0x84 / 255.0, blue: 0x8a / 255.0, alpha: 1)
    /// `--trees-status-ignored`: light #adadb1, dark #4a4a4e.
    static let ignoredFG = NSColor(name: nil) { $0.isDark ? NSColor(srgbRed: 0x4a / 255.0, green: 0x4a / 255.0, blue: 0x4e / 255.0, alpha: 1)
        : NSColor(srgbRed: 0xad / 255.0, green: 0xad / 255.0, blue: 0xb1 / 255.0, alpha: 1) }

    func configure(_ row: FileTreeModel.Row, selected: Bool, guides showGuides: Bool) {
        let iconChanged = row.isDirectory != self.row.isDirectory || (!row.isDirectory && row.path != self.row.path) || icon.superview == nil
        self.row = row
        self.selected = selected
        if iconChanged {
            icon.removeFromSuperview()
            icon = row.isDirectory ? IconView(definition: Self.chevron, size: 16, color: Self.mutedFG) : FileTypeIcon.view(for: row.path, size: 16)
            addSubview(icon)
        }
        if row.ignored, !row.isDirectory { icon.fillColor = Self.ignoredFG; icon.strokeColor = Self.ignoredFG }
        label.text = row.label
        label.font = DSFont.ui(12, weight: row.isSearchMatch ? .semibold : .regular)
        label.color = row.ignored ? Self.ignoredFG : Themed.color(\.contrastForeground)
        while guides.count < row.depth {
            let g = CALayer()
            g.actions = ["frame": NSNull(), "opacity": NSNull(), "position": NSNull(), "bounds": NSNull()]
            layer?.addSublayer(g)
            guides.append(g)
        }
        for (i, g) in guides.enumerated() { g.isHidden = i >= row.depth; g.opacity = showGuides ? 0.75 : 0 }
        setAccessibilityRole(.button)
        setAccessibilityLabel(row.label)
        needsLayout = true
        needsDisplay = true
    }

    /// x of the icon: padding, then per level the guide column (`spacing` and `spacing-item`).
    static func iconX(depth: Int) -> CGFloat {
        guard depth > 0 else { return FileTreeView.paddingX }
        let first: CGFloat = 7.5 + 1 + (FileTreeView.levelGap - 1)
        let next: CGFloat = (FileTreeView.rowGap + 7.5) + 1 + (FileTreeView.levelGap - 1)
        return FileTreeView.paddingX + first + CGFloat(depth - 1) * next + FileTreeView.rowGap
    }

    override func layout() {
        super.layout()
        var x = FileTreeView.paddingX + 7.5
        for (i, g) in guides.enumerated() where i < row.depth {
            g.frame = CGRect(x: x - 0.25, y: 0, width: 1, height: bounds.height)
            x += 1 + (FileTreeView.levelGap - 1) + FileTreeView.rowGap + 7.5
        }
        let ix = Self.iconX(depth: row.depth)
        // `--trees-icon-nudge` puts the open chevron 0.8px lower.
        let nudge: CGFloat = row.isDirectory && row.isExpanded ? 0.8 : 0
        icon.frameCenterRotation = 0
        icon.frame = NSRect(x: ix, y: 4 + nudge, width: 16, height: 16)
        // Closed folders turn the chevron -90°.
        if row.isDirectory, !row.isExpanded { icon.frameCenterRotation = -90 }
        if status.superview == nil { addSubview(status) }
        status.frame = NSRect(x: bounds.width - 18, y: 5, width: 14, height: 14)
        let tx = ix + 16 + FileTreeView.rowGap
        label.frame = NSRect(x: tx, y: 0, width: max(0, bounds.width - tx - FileTreeView.paddingX - (change == nil ? 0 : 18)), height: 24)
    }

    override func updateLayer() {
        let fg = Themed.color(\.contrastForeground)
        let fill: NSColor? = selected ? fg.withAlphaComponent(0.12) : hovered ? fg.withAlphaComponent(0.07) : nil
        layer?.backgroundColor = fill?.cgColor(in: self)
        let guide = Self.mutedFG.withAlphaComponent(0.25).cgColor(in: self)
        guides.forEach { $0.backgroundColor = guide }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        hovered = false
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) { downPoint = event.locationInWindow }
    override func rightMouseDown(with event: NSEvent) { onContextMenu?(row.path, self, event) }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downPoint, hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) > 3,
              let payload = onDragPayload?(row.path) else { return }
        downPoint = nil
        let item = NSPasteboardItem()
        item.setString(payload, forType: .composerMention)
        item.setString(payload, forType: .string)
        let dragging = NSDraggingItem(pasteboardWriter: item)
        let image = NSImage(size: bounds.size, flipped: true) { [weak self] _ in
            guard let self, let ctx = NSGraphicsContext.current else { return false }
            self.layer?.render(in: ctx.cgContext)
            return true
        }
        dragging.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [dragging], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        defer { downPoint = nil }
        guard downPoint != nil, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?(row)
    }
}

extension FileTreeRowView: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .copy : []
    }
}

public extension NSPasteboard.PasteboardType {
    /// `COMPOSER_MENTION_DRAG_TYPE` (composerMentionDrag.ts): a serialized file mention.
    static let composerMention = NSPasteboard.PasteboardType("application/x-t3code-composer-mention")
}
