import AppKit
import DesignSystem
import SpaceModel

/// Space's notebook glyph: Hugeicons `notebook` (stroke-rounded, MIT) as Redesign's duotone, a 16% fill under a 1.8
/// stroke. The icon generator reads T3's imports, which never name it, so it lives here.
public enum SpaceIcons {
    public static let notebook = IconDefinition(viewBox: IconViewBox(x: 0, y: 0, width: 24, height: 24), elements: [
        IconElement(.path(d: "M12.5 2C8.729 2 6.843 2 5.672 3.172S4.5 6.229 4.5 10v4c0 3.771 0 5.657 1.172 6.828S8.729 22 12.5 22h.5c3.771 0 5.657 0 6.828-1.172S21 17.771 21 14v-4c0-3.771 0-5.657-1.172-6.828S16.771 2 13 2z"), IconPaint(fill: .current, stroke: .none, opacity: 0.16)),
        IconElement(.path(d: "M10 11h3.5M10 7h7m-4-5h-.5C8.729 2 6.843 2 5.672 3.172S4.5 6.229 4.5 10v4c0 3.771 0 5.657 1.172 6.828S8.729 22 12.5 22h.5c3.771 0 5.657 0 6.828-1.172S21 17.771 21 14v-4c0-3.771 0-5.657-1.172-6.828S16.771 2 13 2M6 6H3m3 6H3m3 6H3"), IconPaint(stroke: .current, strokeWidth: 1.8, lineCap: .round, lineJoin: .round)),
    ])
}

/// What Space mode asks the app to do.
@MainActor
public struct SpaceSidebarActions {
    /// "‹ Threads": back to the threads sidebar. Space tabs stay open.
    public var back: () -> Void = {}
    public var openPage: (PageID) -> Void = { _ in }
    public var openTrash: () -> Void = {}
    /// A page went to Trash, so the app can close its tab.
    public var trashed: (PageID) -> Void = { _ in }
    public init() {}
}

/// The sidebar in Space mode (docs/space.md "Space mode", mockup look B): "‹ Threads", the "Space" title with Trash,
/// "Search pages", the page tree and "+ New page" pinned above the account row, which the sidebar keeps.
public final class SpaceSidebarView: DSView {
    public var actions = SpaceSidebarActions()
    public let store: SpacePageStore
    let backRow = SidebarNavRowView(.chevronLeft, "Threads")
    let title = LabelView("Space", font: SB.font(15, .medium), color: SB.c(\.sidebarForeground))
    let trashButton = SidebarContentView.headerButton(.trash2, "Trash")
    let search = SidebarSearchFieldView()
    let tree: SpaceTreeView
    let scroll: ScrollAreaView
    let newPageRow = SidebarNavRowView(.plus, "New page")
    private let empty = LabelView("", font: SB.font(13), color: SB.c(\.sidebarMutedForeground))
    private var token: Int?
    /// The bottom edge the sidebar leaves free above its footer.
    public var footerTop: CGFloat = 0 { didSet { if footerTop != oldValue { needsLayout = true } } }

    /// The open page's row is highlighted.
    public var selectedPage: PageID? {
        get { tree.selected }
        set { tree.selected = newValue }
    }

    public init(store: SpacePageStore, settings: SpaceSettings = .shared) {
        self.store = store
        tree = SpaceTreeView(store: store, settings: settings)
        scroll = ScrollAreaView(documentView: tree, scrollFade: true)
        super.init(frame: .zero)
        newPageRow.muted = true
        title.lineHeight = 20
        empty.lineHeight = 20
        search.placeholder = "Search pages"
        search.field.setAccessibilityLabel("Search pages")
        search.clearButton.setAccessibilityLabel("Clear page search")
        [backRow, title, trashButton, search, scroll, empty, newPageRow].forEach(addSubview)
        backRow.action = { [weak self] in self?.actions.back() }
        trashButton.action = { [weak self] in self?.actions.openTrash() }
        newPageRow.action = { [weak self] in self?.newPage(in: nil) }
        search.onChange = { [weak self] q in self?.tree.query = q; self?.syncEmpty() }
        search.onCommand = { [weak self] sel in
            guard let self else { return false }
            switch sel {
            case #selector(NSResponder.insertNewline(_:)):
                // Return opens the first match.
                if let first = tree.rows.first(where: \.matches) { actions.openPage(first.id) }
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                if search.text.isEmpty { return false }
                search.text = ""
                tree.query = ""
                syncEmpty()
                return true
            default: return false
            }
        }
        tree.onOpen = { [weak self] id in self?.actions.openPage(id) }
        tree.onNewChild = { [weak self] parent in self?.newPage(in: parent) }
        tree.onTrash = { [weak self] id in self?.actions.trashed(id) }
        tree.onRowsChange = { [weak self] in self?.syncEmpty() }
        token = store.observe { [weak self] in self?.tree.reload() }
        tree.reload()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    isolated deinit { if let token { store.removeObserver(token) } }

    /// ⌘N in Space mode, the hover +, and + New page: an empty page that opens, with its row ready to name.
    @discardableResult
    public func newPage(in parent: PageID?) -> PageID {
        if !search.text.isEmpty { search.text = ""; tree.query = "" }
        let id = store.createPage(in: parent)
        if let parent { tree.setExpanded(parent, true) }
        tree.reload()
        actions.openPage(id)
        tree.beginRename(id)
        return id
    }

    /// ⌘P in Space mode.
    public func focusSearch() {
        window?.makeFirstResponder(search.field)
        search.field.currentEditor()?.selectAll(nil)
    }

    private func syncEmpty() {
        let none = tree.rows.isEmpty
        empty.isHidden = !none
        empty.text = tree.query.trimmingCharacters(in: .whitespaces).isEmpty ? "No pages yet" : "No pages match"
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        title.color = SB.c(\.sidebarForeground)
        empty.color = SB.c(\.sidebarMutedForeground)
    }

    public override func layout() {
        super.layout()
        let w = bounds.width
        var y: CGFloat = 0
        backRow.frame = NSRect(x: 8, y: y, width: max(0, w - 16), height: SidebarNavRowView.height)
        y += SidebarNavRowView.height + 10
        title.frame = NSRect(x: 16, y: y + 2, width: max(0, w - 16 - 40), height: 20)
        trashButton.frame = NSRect(x: w - 8 - 24, y: y, width: 24, height: 24)
        y += 24 + 6
        search.frame = NSRect(x: 8, y: y, width: max(0, w - 16), height: SidebarNavRowView.height)
        y += SidebarNavRowView.height + 6
        let bottom = max(y, footerTop - SidebarNavRowView.height - 8)
        newPageRow.frame = NSRect(x: 8, y: bottom, width: max(0, w - 16), height: SidebarNavRowView.height)
        scroll.frame = NSRect(x: 0, y: y, width: w, height: max(0, bottom - 4 - y))
        empty.frame = NSRect(x: 16, y: y + 4, width: max(0, w - 32), height: 20)
        tree.frame.size.width = w
        tree.needsLayout = true
    }
}

/// Where a dragged page lands, by the row under the pointer: the top quarter puts it before the row, the bottom
/// quarter after it (as the first child when the row is open), the middle inside it. Below the rows it goes last at
/// the top level.
public enum SpaceDrop: Equatable {
    case before(PageID), after(PageID), into(PageID), end

    /// The drop at `y` in a tree of `rows`, each `pitch` tall, or nil where `dragged` can't go.
    public static func plan(y: CGFloat, rows: [SpaceTreeRow], pitch: CGFloat, dragged: PageID, pages: [PageID: PageRecord]) -> SpaceDrop? {
        guard y >= 0 else { return rows.first.map { .before($0.id) } }
        let i = Int(y / pitch)
        guard i < rows.count else { return .end }
        let row = rows[i]
        if SpaceTree.isDescendant(row.id, of: dragged, in: pages) { return nil }
        let f = (y - CGFloat(i) * pitch) / pitch
        if f < 0.25 { return .before(row.id) }
        if f > 0.75 { return .after(row.id) }
        return pages[row.id]?.view == .page ? .into(row.id) : (f < 0.5 ? .before(row.id) : .after(row.id))
    }

    /// The parent and the sibling to go before, for `SpacePageStore.move`.
    public func target(rows: [SpaceTreeRow], dragged: PageID, pages: [PageID: PageRecord]) -> (parent: PageID?, before: PageID?) {
        switch self {
        case .end: return (nil, nil)
        case .into(let id): return (id, nil)
        case .before(let id): return (pages[id]?.parent, id)
        case .after(let id):
            if let row = rows.first(where: { $0.id == id }), row.expanded {
                return (id, SpaceTree.children(of: id, in: pages).first { $0 != dragged })
            }
            let parent = pages[id]?.parent
            let siblings = SpaceTree.children(of: parent, in: pages).filter { $0 != dragged }
            let next = siblings.firstIndex(of: id).flatMap { siblings.indices.contains($0 + 1) ? siblings[$0 + 1] : nil }
            return (parent, next)
        }
    }
}

/// The page tree: 28pt rows 2pt apart, 16pt deeper per level, no icons, children under a faint guide line. It draws
/// its rows, tracks hover itself and runs clicks and drags, so the rows stay plain views.
final class SpaceTreeView: DSView {
    static let rowHeight: CGFloat = 28
    static let pitch: CGFloat = 30
    let store: SpacePageStore
    let settings: SpaceSettings
    private(set) var rows: [SpaceTreeRow] = []
    private var views: [PageID: SpaceTreeRowView] = [:]
    private var guides: [CALayer] = []
    var onOpen: (PageID) -> Void = { _ in }
    var onNewChild: (PageID) -> Void = { _ in }
    var onTrash: (PageID) -> Void = { _ in }
    var onRowsChange: () -> Void = {}
    var query = "" { didSet { if query != oldValue { reload() } } }
    var selected: PageID? { didSet { if selected != oldValue { for v in views.values { v.isSelected = v.id == selected } } } }
    private var hovered: PageID? {
        didSet {
            guard hovered != oldValue else { return }
            if let oldValue { views[oldValue]?.isHovered = false }
            if let hovered { views[hovered]?.isHovered = true }
        }
    }
    private var press: (point: NSPoint, id: PageID?, onChevron: Bool)?
    private var drag: (id: PageID, drop: SpaceDrop?)?
    private let line = SidebarDropLineView()
    private var renaming: (id: PageID, field: NSTextField)?

    init(store: SpacePageStore, settings: SpaceSettings) {
        self.store = store
        self.settings = settings
        super.init(frame: .zero)
        line.isHidden = true
        addSubview(line)
        setAccessibilityRole(.outline)
        setAccessibilityLabel("Pages")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func setExpanded(_ id: PageID, _ open: Bool) {
        var set = settings.expanded
        if open { set.insert(id) } else { set.remove(id) }
        settings.expanded = set
    }

    func reload() {
        rows = SpaceTree.rows(store.pages, expanded: settings.expanded, query: query)
        var keep: [PageID: SpaceTreeRowView] = [:]
        for row in rows {
            let v = views[row.id] ?? makeRow(row.id)
            v.row = row
            v.isSelected = row.id == selected
            keep[row.id] = v
        }
        for (id, v) in views where keep[id] == nil { v.removeFromSuperview() }
        views = keep
        if let r = renaming, views[r.id] == nil { endRename(commit: false) }
        if let h = hovered, views[h] == nil { hovered = nil }
        setFrameSize(NSSize(width: frame.width, height: CGFloat(rows.count) * Self.pitch + 8))
        needsLayout = true
        onRowsChange()
    }

    private func makeRow(_ id: PageID) -> SpaceTreeRowView {
        let v = SpaceTreeRowView(id: id)
        v.onHover = { [weak self] inside in self?.rowHover(id, inside) }
        v.plus.action = { [weak self] in self?.onNewChild(id) }
        v.more.action = { [weak self, weak v] in
            guard let self, let v else { return }
            self.showMenu(id, at: NSPoint(x: 0, y: v.more.bounds.maxY + 4), in: v.more)
        }
        addSubview(v, positioned: .below, relativeTo: line)
        return v
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        guides.forEach { $0.removeFromSuperlayer() }
        guides = []
        // A guide runs from a parent's first child to its last descendant row, under the parent's chevron.
        for (i, row) in rows.enumerated() where row.expanded {
            var end = i + 1
            while end < rows.count && rows[end].depth > row.depth { end += 1 }
            let g = CALayer()
            g.backgroundColor = Themed.color(\.border).cgColor(in: self)
            let x = 8 + 8 + CGFloat(row.depth) * 16 + 6
            g.frame = NSRect(x: x, y: CGFloat(i + 1) * Self.pitch, width: 1, height: CGFloat(end - i - 1) * Self.pitch - 2)
            // Under the rows, so a hovered or open row's fill covers it.
            layer?.insertSublayer(g, at: 0)
            guides.append(g)
        }
        CATransaction.commit()
        for (i, row) in rows.enumerated() {
            views[row.id]?.frame = NSRect(x: 8, y: CGFloat(i) * Self.pitch, width: max(0, w - 16), height: Self.rowHeight)
        }
        if let r = renaming, let v = views[r.id] {
            let x = v.frame.minX + v.titleX - 2
            r.field.frame = NSRect(x: x, y: v.frame.minY + 4, width: max(0, v.frame.maxX - 6 - x), height: 20)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    // MARK: Hover


    /// Each row tracks the pointer itself: the window sends no mouse moves to a tracking area here.
    private func rowHover(_ id: PageID, _ inside: Bool) {
        if inside { hovered = drag == nil ? id : nil } else if hovered == id { hovered = nil }
    }

    private func rowIndex(at p: NSPoint) -> Int? {
        let i = Int(p.y / Self.pitch)
        guard p.y >= 0, i < rows.count, p.y - CGFloat(i) * Self.pitch < Self.rowHeight else { return nil }
        return i
    }
    private func rowId(at p: NSPoint) -> PageID? { rowIndex(at: p).map { rows[$0].id } }

    // MARK: Click, drag

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if renaming != nil { endRename(commit: true) }
        guard let i = rowIndex(at: p) else { press = nil; return }
        let row = rows[i]
        let chevronX = 8 + 8 + CGFloat(row.depth) * 16
        let onChevron = row.hasChildren && p.x >= chevronX - 4 && p.x <= chevronX + 16
        if event.clickCount == 2 && !onChevron { press = nil; beginRename(row.id); return }
        press = (p, row.id, onChevron)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let press, let id = press.id else { return }
        let p = convert(event.locationInWindow, from: nil)
        if drag == nil {
            guard hypot(p.x - press.point.x, p.y - press.point.y) >= 4, query.isEmpty else { return }
            drag = (id, nil)
            hovered = nil
            views[id]?.alphaValue = SidebarListView.ditherDimAlpha
        }
        autoscroll(with: event)
        let drop = SpaceDrop.plan(y: p.y, rows: rows, pitch: Self.pitch, dragged: id, pages: store.pages)
        drag?.drop = drop
        showDrop(drop)
    }

    override func mouseUp(with event: NSEvent) {
        defer { press = nil }
        if let d = drag {
            drag = nil
            views[d.id]?.alphaValue = 1
            showDrop(nil)
            guard let drop = d.drop else { return }
            let t = drop.target(rows: rows, dragged: d.id, pages: store.pages)
            if store.move(d.id, to: t.parent, before: t.before), let parent = t.parent { setExpanded(parent, true); reload() }
            return
        }
        guard let press, let id = press.id, rowId(at: convert(event.locationInWindow, from: nil)) == id else { return }
        if press.onChevron, let row = rows.first(where: { $0.id == id }) {
            if query.isEmpty { setExpanded(id, !row.expanded); reload() }
        } else {
            onOpen(id)
        }
    }

    private func showDrop(_ drop: SpaceDrop?) {
        for v in views.values where v.isDropTarget { v.isDropTarget = false }
        line.isHidden = true
        guard let drop else { return }
        func index(_ id: PageID) -> Int { rows.firstIndex { $0.id == id } ?? 0 }
        let y: CGFloat, depth: Int
        switch drop {
        case .into(let id): views[id]?.isDropTarget = true; return
        case .before(let id): y = CGFloat(index(id)) * Self.pitch - 1; depth = rows[index(id)].depth
        case .after(let id):
            let i = index(id)
            y = CGFloat(i) * Self.pitch + Self.rowHeight + 1
            depth = rows[i].depth + (rows[i].expanded ? 1 : 0)
        case .end: y = CGFloat(rows.count) * Self.pitch - 1; depth = 0
        }
        let x = 8 + 8 + CGFloat(depth) * 16
        line.frame = NSRect(x: x, y: y - 1, width: max(0, bounds.width - 8 - x), height: 2)
        line.isHidden = false
    }

    // MARK: Menu

    override func rightMouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let id = rowId(at: p) else { return }
        showMenu(id, at: p, in: self)
    }

    private func showMenu(_ id: PageID, at point: NSPoint, in view: NSView) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(SpaceMenuItem("Rename") { [weak self] in self?.beginRename(id) })
        let move = NSMenuItem(title: "Move to", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        sub.addItem(SpaceMenuItem("Top level") { [weak self] in self?.store.move(id, to: nil, before: nil) })
        sub.addItem(.separator())
        let pages = store.pages
        for target in SpaceTree.rows(pages, expanded: Set(pages.keys)) where !SpaceTree.isDescendant(target.id, of: id, in: pages) {
            let item = SpaceMenuItem(target.title.isEmpty ? "Untitled" : target.title) { [weak self] in
                guard let self else { return }
                store.move(id, to: target.id, before: nil)
                setExpanded(target.id, true)
                reload()
            }
            item.indentationLevel = min(target.depth, 15)
            item.isEnabled = pages[target.id]?.view == .page && pages[id]?.parent != target.id
            sub.addItem(item)
        }
        move.submenu = sub
        menu.addItem(move)
        menu.addItem(SpaceMenuItem("Duplicate") { [weak self] in
            guard let self, let copy = store.duplicate(id) else { return }
            onOpen(copy)
        })
        menu.addItem(.separator())
        menu.addItem(SpaceMenuItem("Move to Trash") { [weak self] in
            self?.store.trash(id)
            self?.onTrash(id)
        })
        views[id]?.menuOpen = true
        menu.popUp(positioning: nil, at: point, in: view)
        views[id]?.menuOpen = false
    }

    // MARK: Rename

    func beginRename(_ id: PageID) {
        guard let v = views[id] else { return }
        endRename(commit: true)
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = SB.font(13)
        field.textColor = SB.c(\.sidebarForeground)
        field.placeholderString = "Untitled"
        field.stringValue = store.pages[id]?.title ?? ""
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.setAccessibilityLabel("Page title")
        field.target = self
        field.action = #selector(renameCommitted)
        addSubview(field)
        renaming = (id, field)
        v.hidesTitle = true
        needsLayout = true
        layoutSubtreeIfNeeded()
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        NotificationCenter.default.addObserver(self, selector: #selector(renameEnded), name: NSControl.textDidEndEditingNotification, object: field)
    }

    @objc private func renameCommitted() { endRename(commit: true) }
    @objc private func renameEnded(_ note: Notification) {
        let cancelled = (note.userInfo?["NSTextMovement"] as? Int) == NSTextMovement.cancel.rawValue
        endRename(commit: !cancelled)
    }

    private func endRename(commit: Bool) {
        guard let r = renaming else { return }
        renaming = nil
        NotificationCenter.default.removeObserver(self, name: NSControl.textDidEndEditingNotification, object: r.field)
        let title = r.field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        r.field.removeFromSuperview()
        views[r.id]?.hidesTitle = false
        if commit { store.rename(r.id, title) }
    }

    override func cancelOperation(_ sender: Any?) {
        if renaming != nil { endRename(commit: false) } else { super.cancelOperation(sender) }
    }
}

/// An NSMenuItem that runs a closure.
final class SpaceMenuItem: NSMenuItem {
    private let run: () -> Void
    init(_ title: String, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    @available(*, unavailable) required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { run() }
}

/// One tree row: the chevron on rows with child pages, the title, and on hover + for a child page and ⋯.
final class SpaceTreeRowView: DSView {
    let id: PageID
    private let chevron = IconView(name: .chevronRight, size: 12)
    private let label = LabelView("", font: SB.font(13), color: SB.c(\.sidebarForeground))
    let plus = RowActionButton(icon: .plus, size: 14, accessibility: "Add a page inside")
    let more = RowActionButton(icon: .ellipsis, size: 14, accessibility: "More actions").menuTrigger()
    var row: SpaceTreeRow? { didSet { if row != oldValue { refresh() } } }
    var isSelected = false { didSet { if isSelected != oldValue { refresh() } } }
    var isHovered = false { didSet { if isHovered != oldValue { refresh() } } }
    var isDropTarget = false { didSet { if isDropTarget != oldValue { refresh() } } }
    var menuOpen = false { didSet { if menuOpen != oldValue { refresh() } } }
    var hidesTitle = false { didSet { label.isHidden = hidesTitle } }
    var titleX: CGFloat { 8 + CGFloat(row?.depth ?? 0) * 16 + 12 + 6 }
    var onHover: (Bool) -> Void = { _ in }

    init(id: PageID) {
        self.id = id
        super.init(frame: .zero)
        label.lineHeight = 20
        for b in [plus, more] { b.padding = 3; b.isHidden = true; addSubview(b) }
        addSubview(chevron)
        addSubview(label)
        layer?.cornerRadius = DitherChrome.controlRadius
        setAccessibilityElement(true)
        setAccessibilityRole(.row)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover(true) }
    override func mouseExited(with event: NSEvent) { onHover(false) }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Clicks land on the tree, except on the hover buttons.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit is RowActionButton || hit?.superview is RowActionButton ? hit : nil
    }

    private func refresh() {
        guard let row else { return }
        label.text = row.title.isEmpty ? "Untitled" : row.title
        let active = isHovered || menuOpen
        label.color = SB.c(row.matches ? \.sidebarForeground : \.sidebarMutedForeground, row.title.isEmpty || !row.matches ? 0.7 : isSelected ? 1 : 0.92)
        chevron.isHidden = !row.hasChildren
        chevron.strokeColor = SB.c(\.sidebarMutedForeground)
        chevron.setRotation(row.expanded ? 90 : 0, motion: window == nil ? .none : .ease(0.15))
        plus.isHidden = !active
        more.isHidden = !active
        needsDisplay = true
        needsLayout = true
        setAccessibilityLabel(label.text)
        if row.hasChildren { setAccessibilityExpanded(row.expanded) }
        setAccessibilitySelected(isSelected)
        updateLayer()
    }

    override func updateLayer() {
        let fill: NSColor? = isSelected ? SB.c(\.sidebarRowActive) : isDropTarget || isHovered || menuOpen ? SB.c(\.sidebarRowHover) : nil
        layer?.backgroundColor = fill?.cgColor(in: self)
    }

    override func layout() {
        super.layout()
        let depth = CGFloat(row?.depth ?? 0)
        chevron.frame = NSRect(x: 8 + depth * 16, y: (bounds.height - 12) / 2, width: 12, height: 12)
        let buttons: CGFloat = plus.isHidden ? 0 : 2 * 20 + 2 + 4
        more.frame = NSRect(x: bounds.width - 4 - 20, y: (bounds.height - 20) / 2, width: 20, height: 20)
        plus.frame = NSRect(x: more.frame.minX - 2 - 20, y: more.frame.minY, width: 20, height: 20)
        label.frame = NSRect(x: titleX, y: (bounds.height - 20) / 2, width: max(0, bounds.width - titleX - 8 - buttons), height: 20)
    }
}
