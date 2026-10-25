import AppKit
import DesignSystem
import SpaceEngine
import SpaceFields
import SpaceModel
import UniformTypeIdentifiers

/// Table view (docs/space.md "Table"): mockup look B's rows with dividers only, look A's type icons in the headers
/// and A's select pills. Only the visible rows have views, recycled as the list scrolls.
final class SpaceTableView: DSView {
    let model: SpaceTableModel
    let scroll = NSScrollView()
    let doc: SpaceTableDocument
    /// "Deleted <field>" with Undo.
    let toasts = ToastViewport()

    init(store: SpaceDocumentStore, page: PageID) {
        model = SpaceTableModel(store: store, page: page)
        doc = SpaceTableDocument(model: model)
        super.init(frame: .zero)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = doc
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        addSubview(scroll)
        addSubview(toasts)
        model.onChange = { [weak self] in self?.doc.reloadData() }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// SpacePageView.itemViews' entry for `.table`.
    static func make(_ store: SpaceDocumentStore, _ page: PageID, _ host: SpacePageView) -> NSView { SpaceTableView(store: store, page: page) }

    isolated deinit { NotificationCenter.default.removeObserver(self) }

    /// SpacePageView adds its header here; it scrolls with the table, so it moves into the document.
    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        if let header = subview as? SpacePageHeaderView { doc.adopt(header) }
    }

    @objc private func scrolled() {
        doc.tile()
        if let window { doc.updateHover(doc.convert(window.mouseLocationOutsideOfEventStream, from: nil)) }
    }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        toasts.frame = ToastViewport.frame(in: bounds, dither: ThemeRuntime.isDither(dark: effectiveAppearance.isDark))
        doc.layoutDocument()
    }
}

/// Everything that scrolls: the page header, the toolbar, the header row, the rows and "+ New".
final class SpaceTableDocument: DSView, NSTextFieldDelegate, HoverSyncPointerClient {
    enum Metrics {
        static let margin: CGFloat = 32
        static let toolbarY: CGFloat = 154
        static let headerY: CGFloat = 196
        static let row: CGFloat = 32
        static var rowsTop: CGFloat { headerY + row }
        static let addColumn: CGFloat = 36
        static let handle: CGFloat = 22
    }

    struct CellRef: Equatable { var row: PageID; var column: String }

    let model: SpaceTableModel
    private weak var header: SpacePageHeaderView?
    let headerRow = SpaceTableHeaderRow()
    let newRow = SpaceTableNewRow()
    let filterButton = SpaceTableToolButton(title: "Filter", icon: .listFilter)
    let sortButton = SpaceTableToolButton(title: "Sort", icon: .arrowUpDown)
    let fieldsButton = SpaceTableToolButton(title: "Fields", icon: .slidersHorizontal)
    let hint = LabelView("Clear the sort to reorder", font: DSFont.ui(12), color: Themed.color(\.placeholder))
    private let dropLine = DSView()
    let editor = SpaceTableCellEditor()

    /// Row views by row index, for visible rows only.
    private(set) var visible: [Int: SpaceTableRowView] = [:]
    private var spare: [SpaceTableRowView] = []
    private(set) var rowIndex: [PageID: Int] = [:]
    var selection: CellRef? { didSet { if selection != oldValue { selectionChanged(from: oldValue) } } }
    private(set) var hoverRow: Int? { didSet { if hoverRow != oldValue { redraw(row: oldValue); redraw(row: hoverRow) } } }
    private var hoverNew = false { didSet { newRow.hovered = hoverNew } }
    /// A column being resized, with its live width.
    private var resizing: (id: String, start: CGFloat, x: CGFloat)?
    private var liveWidth: [String: CGFloat] = [:]
    private var dragging: (id: PageID, target: Int)?
    private var editing: (ref: CellRef?, header: String?)?
    private(set) var popupMenu: MenuPopupView?
    weak var filesPopover: SpaceFilesPopover?

    init(model: SpaceTableModel) {
        self.model = model
        super.init(frame: .zero)
        headerRow.doc = self
        newRow.doc = self
        hint.lineHeight = 16
        [headerRow, newRow, filterButton, sortButton, fieldsButton, hint, dropLine].forEach(addSubview)
        dropLine.isHidden = true
        dropLine.layer?.backgroundColor = SpacePageMetrics.accent.cgColor(in: self)
        filterButton.onPress = { [weak self] in self?.showFilterMenu() }
        sortButton.onPress = { [weak self] in self?.showSortMenu() }
        fieldsButton.onPress = { [weak self] in self?.showFieldsMenu() }
        editor.delegate = self
        setAccessibilityRole(.table)
        setAccessibilityLabel("Table")
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        registerForDraggedTypes([.fileURL, .png, .tiff, NSPasteboard.PasteboardType(UTType.svg.identifier)])
        NotificationCenter.default.addObserver(self, selector: #selector(mediaLoaded), name: SpaceMedia.didLoad, object: nil)
        reloadData()
    }

    @objc private func mediaLoaded() { visible.values.forEach { $0.needsDisplay = true } }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        dropLine.layer?.backgroundColor = SpacePageMetrics.accent.cgColor(in: self)
        for v in visible.values { v.needsDisplay = true }
        headerRow.needsDisplay = true
    }

    func adopt(_ header: SpacePageHeaderView) {
        self.header = header
        addSubview(header)
        header.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(headerMoved), name: NSView.frameDidChangeNotification, object: header)
        needsLayout = true
    }

    isolated deinit { NotificationCenter.default.removeObserver(self) }

    /// SpacePageView frames the header to the Page view's column; the other views use the full width.
    @objc private func headerMoved() {
        guard let header, header.superview === self, header.frame != headerFrame else { return }
        header.frame = headerFrame
    }

    /// The header moves on to the next view's document, so this one stops framing it.
    override func willRemoveSubview(_ subview: NSView) {
        super.willRemoveSubview(subview)
        guard subview === header else { return }
        NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: subview)
        header = nil
    }

    private var clip: NSRect { enclosingScrollView?.contentView.bounds ?? bounds }
    private var headerFrame: NSRect {
        NSRect(x: clip.minX + Metrics.margin, y: 0, width: max(240, clip.width - 2 * Metrics.margin), height: header?.height ?? 186)
    }

    // MARK: Geometry

    func width(_ c: SpaceTableModel.Column) -> CGFloat { liveWidth[c.id] ?? c.width }
    /// Column left edges relative to the table's left edge, plus the end.
    var edges: [CGFloat] {
        var out: [CGFloat] = [0]
        for c in model.columns { out.append(out.last! + width(c)) }
        return out
    }
    var tableWidth: CGFloat { (edges.last ?? 0) + Metrics.addColumn }
    func rowY(_ i: Int) -> CGFloat { Metrics.rowsTop + CGFloat(i) * Metrics.row }

    func layoutDocument() {
        guard let scroll = enclosingScrollView else { return }
        let size = NSSize(width: max(scroll.contentSize.width, tableWidth + 2 * Metrics.margin),
                          height: max(scroll.contentSize.height, rowY(model.rows.count) + Metrics.row + 120))
        if frame.size != size { setFrameSize(size) }
        layoutFixed()
        headerRow.frame = NSRect(x: Metrics.margin, y: Metrics.headerY, width: tableWidth, height: Metrics.row)
        newRow.frame = NSRect(x: Metrics.margin, y: rowY(model.rows.count), width: tableWidth, height: Metrics.row)
        for (i, v) in visible { v.frame = rowFrame(i) }
        tile()
    }

    /// The header, toolbar and hint keep their place when the table scrolls sideways.
    private func layoutFixed() {
        let x = clip.minX + Metrics.margin
        if let header, header.frame != headerFrame { header.frame = headerFrame }
        var tx = x - 8
        for b in [filterButton, sortButton, fieldsButton] {
            let w = b.intrinsicContentSize.width
            b.frame = NSRect(x: tx, y: Metrics.toolbarY, width: w, height: 26)
            tx += w + 2
        }
        hint.isHidden = model.canReorder
        hint.frame = NSRect(x: tx + 10, y: Metrics.toolbarY + 5, width: hint.textWidth.rounded(.up) + 2, height: 16)
    }

    private func rowFrame(_ i: Int) -> NSRect { NSRect(x: Metrics.margin, y: rowY(i), width: tableWidth, height: Metrics.row) }

    /// Gives each visible row a view and returns the rest to the spare pool.
    func tile() {
        let c = clip
        layoutFixed()
        let count = model.rows.count
        let first = max(0, Int(((c.minY - Metrics.rowsTop) / Metrics.row).rounded(.down)))
        let last = min(count - 1, Int(((c.maxY - Metrics.rowsTop) / Metrics.row).rounded(.up)))
        let range = first <= last ? first...last : nil
        for (i, v) in visible where !(range?.contains(i) ?? false) {
            visible[i] = nil
            v.isHidden = true
            spare.append(v)
        }
        guard let range else { return }
        for i in range where visible[i] == nil {
            let v = spare.popLast() ?? {
                let v = SpaceTableRowView()
                v.doc = self
                addSubview(v, positioned: .below, relativeTo: dropLine)
                return v
            }()
            v.index = i
            v.isHidden = false
            v.frame = rowFrame(i)
            v.needsDisplay = true
            visible[i] = v
        }
    }

    func reloadData() {
        rowIndex = Dictionary(uniqueKeysWithValues: model.rows.enumerated().map { ($0.element.id, $0.offset) })
        if let s = selection, rowIndex[s.row] == nil || !model.columns.contains(where: { $0.id == s.column }) { selection = nil }
        filterButton.isActive = !model.filters.isEmpty
        filterButton.badge = model.filters.isEmpty ? nil : "\(model.filters.count)"
        sortButton.isActive = !model.sorts.isEmpty
        sortButton.badge = model.sorts.isEmpty ? nil : "\(model.sorts.count)"
        for v in visible.values { v.needsDisplay = true }
        headerRow.needsDisplay = true
        filesPopover?.refresh()
        layoutDocument()
        window?.invalidateCursorRects(for: self)
    }

    private func redraw(row: Int?) { if let row { visible[row]?.needsDisplay = true } }

    private func selectionChanged(from old: CellRef?) {
        if let old, let i = rowIndex[old.row] { redraw(row: i) }
        if let s = selection, let i = rowIndex[s.row] { redraw(row: i) }
    }

    func columnIndex(atX x: CGFloat) -> Int? {
        let e = edges
        let local = x - Metrics.margin
        for i in 0..<model.columns.count where local >= e[i] && local < e[i + 1] { return i }
        return nil
    }

    func cellRect(row: Int, column: Int) -> NSRect {
        let e = edges
        return NSRect(x: Metrics.margin + e[column], y: rowY(row), width: e[column + 1] - e[column], height: Metrics.row)
    }

    // MARK: Pointer

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        // Rows, the header row and "+ New" draw only; the document handles their clicks.
        if hit is SpaceTableRowView || hit === headerRow || hit === newRow { return self }
        return hit
    }

    override func resetCursorRects() {
        let e = edges
        for x in e.dropFirst().dropLast(0) where model.columns.count > 0 {
            addCursorRect(NSRect(x: Metrics.margin + x - 3, y: Metrics.headerY, width: 6, height: Metrics.row), cursor: .resizeLeftRight)
        }
    }

    /// HoverSync delivers enter, exit and pointer moves for DSViews.
    func hoverPointerMoved() { if let window { updateHover(convert(window.mouseLocationOutsideOfEventStream, from: nil)) } }
    override func mouseEntered(with event: NSEvent) { hoverPointerMoved() }
    override func mouseMoved(with event: NSEvent) { updateHover(convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { hoverRow = nil; hoverNew = false }

    func updateHover(_ p: NSPoint) {
        let inTable = p.x >= Metrics.margin - Metrics.handle && p.x < Metrics.margin + tableWidth
        let i = Int(((p.y - Metrics.rowsTop) / Metrics.row).rounded(.down))
        hoverRow = inTable && p.y >= Metrics.rowsTop && i < model.rows.count ? i : nil
        hoverNew = inTable && newRow.frame.contains(NSPoint(x: max(p.x, Metrics.margin), y: p.y))
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        endEditing(commit: true)
        window?.makeFirstResponder(self)
        if p.y >= Metrics.headerY && p.y < Metrics.rowsTop { headerDown(p, event); return }
        if newRow.frame.contains(p) { addRowAndEdit(); return }
        let i = Int(((p.y - Metrics.rowsTop) / Metrics.row).rounded(.down))
        guard p.y >= Metrics.rowsTop, i < model.rows.count else { selection = nil; return }
        if p.x < Metrics.margin && p.x >= Metrics.margin - Metrics.handle {
            if model.canReorder { dragRow(i, event) }
            return
        }
        guard let c = columnIndex(atX: p.x) else { selection = nil; return }
        let column = model.columns[c]
        let ref = CellRef(row: model.rows[i].id, column: column.id)
        let wasSelected = selection == ref
        selection = ref
        let cell = cellRect(row: i, column: c)
        if column.isTitle, let slot = iconSlot(row: i, cell: cell), slot.contains(p) { showIconPicker(i, anchor: slot); return }
        if column.type == .files, wasSelected || event.clickCount == 2 {
            let refs = model.files(i, column)
            if let k = SpaceTableCellDrawing.thumbIndex(refs, at: p.x - cell.minX, width: cell.width), refs[k].mime.hasPrefix("image/"), let window {
                SpaceMedia.expand(refs, index: k, in: window)
                return
            }
        }
        if column.type == .checkbox { model.toggle(i, column); return }
        if event.clickCount == 2 || wasSelected { activate() }
    }

    // MARK: Drop

    /// A drop on a Files & media cell attaches; a drop on a title sets the row's icon.
    private func dropTarget(_ sender: NSDraggingInfo) -> (row: Int, column: SpaceTableModel.Column)? {
        let p = convert(sender.draggingLocation, from: nil)
        let i = Int(((p.y - Metrics.rowsTop) / Metrics.row).rounded(.down))
        guard p.y >= Metrics.rowsTop, i < model.rows.count, let c = columnIndex(atX: p.x) else { return nil }
        let column = model.columns[c]
        return column.isTitle || column.type == .files ? (i, column) : nil
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard SpaceMedia.canRead(sender.draggingPasteboard), let t = dropTarget(sender) else { return [] }
        selection = CellRef(row: model.rows[t.row].id, column: t.column.id)
        return .copy
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let t = dropTarget(sender) else { return false }
        let files = SpaceMedia.files(from: sender.draggingPasteboard)
        guard !files.isEmpty else { return false }
        if t.column.isTitle { setIcon(from: files, row: model.rows[t.row].id) }
        else { attach(files, row: model.rows[t.row].id, column: t.column.id) }
        return true
    }

    override func rightMouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let i = Int(((p.y - Metrics.rowsTop) / Metrics.row).rounded(.down))
        guard p.y >= Metrics.rowsTop, i < model.rows.count else { return }
        let id = model.rows[i].id
        let items = [
            MenuItem("Open", icon: .fileText) { [weak self] in self?.open(id) },
            MenuItem("Icon…", icon: .smilePlus) { [weak self] in
                guard let self, let i = self.rowIndex[id] else { return }
                let anchor = self.model.columns.first?.isTitle == true ? self.cellRect(row: i, column: 0) : NSRect(x: p.x, y: p.y, width: 1, height: 1)
                DispatchQueue.main.async { self.showIconPicker(i, anchor: anchor) }
            },
            .separator,
            MenuItem("Delete row", icon: .trash2, destructive: true) { [weak self] in
                guard let self, let i = self.rowIndex[id] else { return }
                self.model.trashRow(i)
            },
        ]
        openMenu(items, anchor: NSRect(x: p.x, y: p.y, width: 1, height: 1), width: 160)
    }

    private func open(_ id: PageID) {
        var v: NSView? = superview
        while let cur = v, !(cur is SpacePageView) { v = cur.superview }
        (v as? SpacePageView)?.onOpenPage(id)
    }

    private func headerDown(_ p: NSPoint, _ event: NSEvent) {
        let e = edges
        let local = p.x - Metrics.margin
        if let edge = e.indices.dropFirst().first(where: { abs(e[$0] - local) <= 3 }) {
            let column = model.columns[edge - 1]
            resizing = (column.id, width(column), p.x)
            return
        }
        if local >= e.last!, local < e.last! + Metrics.addColumn {
            showAddFieldMenu(anchor: NSRect(x: Metrics.margin + e.last!, y: Metrics.headerY, width: Metrics.addColumn, height: Metrics.row))
            return
        }
        guard let c = columnIndex(atX: p.x) else { return }
        showHeaderMenu(c)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let r = resizing else { return }
        let x = convert(event.locationInWindow, from: nil).x
        liveWidth[r.id] = max(SpaceTableModel.minWidth, r.start + x - r.x)
        relayoutColumns()
    }

    override func mouseUp(with event: NSEvent) {
        guard let r = resizing else { return }
        resizing = nil
        if let w = liveWidth[r.id], w != r.start { model.resize(r.id, to: w) }
        liveWidth = [:]
        reloadData()
        window?.invalidateCursorRects(for: self)
    }

    private func relayoutColumns() {
        headerRow.needsDisplay = true
        for v in visible.values { v.needsDisplay = true }
        layoutDocument()
    }

    /// Drags a row by its handle, drawing the accent line where it will land.
    private func dragRow(_ index: Int, _ event: NSEvent) {
        let id = model.rows[index].id
        var target = index
        window?.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: .infinity, mode: .eventTracking) { [weak self] e, stop in
            guard let self, let e else { stop.pointee = true; return }
            let y = self.convert(e.locationInWindow, from: nil).y
            target = min(self.model.rows.count, max(0, Int(((y - Metrics.rowsTop) / Metrics.row).rounded())))
            if e.type == .leftMouseUp {
                stop.pointee = true
                self.dropLine.isHidden = true
                if target != index && target != index + 1 {
                    self.model.moveRow(id, before: target < self.model.rows.count ? self.model.rows[target].id : nil)
                }
                return
            }
            self.autoscroll(with: e)
            self.dropLine.isHidden = false
            self.dropLine.frame = NSRect(x: Metrics.margin, y: self.rowY(target) - 1, width: self.tableWidth - Metrics.addColumn, height: 2)
        }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) { super.keyDown(with: event); return }
        guard let s = selection, let r = rowIndex[s.row], let c = model.columns.firstIndex(where: { $0.id == s.column }) else {
            if event.keyCode == 125 || event.keyCode == 48, !model.rows.isEmpty { select(0, 0) }
            else { super.keyDown(with: event) }
            return
        }
        switch event.keyCode {
        case 123: select(r, max(0, c - 1))
        case 124: select(r, min(model.columns.count - 1, c + 1))
        case 125: select(min(model.rows.count - 1, r + 1), c)
        case 126: select(max(0, r - 1), c)
        case 48: event.modifierFlags.contains(.shift) ? select(r, max(0, c - 1)) : select(r, min(model.columns.count - 1, c + 1))
        case 36, 76: activate()
        case 53: selection = nil
        case 51, 117:
            let column = model.columns[c]
            if column.isTitle { model.setText(r, column, "") } else { model.setValue(r, column, nil) }
        default:
            let column = model.columns[c]
            let chars = event.characters ?? ""
            if column.type == .checkbox, chars == " " { model.toggle(r, column); return }
            if !chars.isEmpty, chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
               column.isTitle || [.text, .number, .url].contains(column.type) {
                beginEditing(r, c, text: chars, replace: true)
            } else { super.keyDown(with: event) }
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "v", let s = selection,
           let column = model.columns.first(where: { $0.id == s.column }), column.type == .files {
            let files = SpaceMedia.files(from: .general)
            guard !files.isEmpty else { NSSound.beep(); return true }
            attach(files, row: s.row, column: column.id)
            return true
        }
        guard window?.firstResponder === self, event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.shift) == .command,
              event.charactersIgnoringModifiers?.lowercased() == "z" else { return super.performKeyEquivalent(with: event) }
        if event.modifierFlags.contains(.shift) { redo(nil) } else { undo(nil) }
        return true
    }

    @objc func undo(_ sender: Any?) { endEditing(commit: true); if model.undo.canUndo { model.undo.undo() } }
    @objc func redo(_ sender: Any?) { endEditing(commit: true); if model.undo.canRedo { model.undo.redo() } }

    func select(_ row: Int, _ column: Int) {
        guard model.rows.indices.contains(row), model.columns.indices.contains(column) else { return }
        selection = CellRef(row: model.rows[row].id, column: model.columns[column].id)
        scrollToVisible(cellRect(row: row, column: column).insetBy(dx: -8, dy: -Metrics.row))
    }

    /// Return on a cell: edit text, open a select or date menu, or tick a checkbox.
    func activate() {
        guard let s = selection, let r = rowIndex[s.row], let c = model.columns.firstIndex(where: { $0.id == s.column }) else { return }
        let column = model.columns[c]
        switch column.type {
        case .checkbox?: model.toggle(r, column)
        case .select?, .multi?: showOptionsMenu(r, column, anchor: cellRect(row: r, column: c))
        case .date?: showDateMenu(r, column, anchor: cellRect(row: r, column: c))
        case .files?: showFilesPopover(r, column, anchor: cellRect(row: r, column: c))
        default: beginEditing(r, c, text: model.editText(r, column), replace: false)
        }
    }

    private func addRowAndEdit() {
        guard let id = model.addRow() else { return }
        guard let i = rowIndex[id] else { return }
        select(i, 0)
        if model.columns.first?.isTitle == true { beginEditing(i, 0, text: "", replace: true) }
    }

    // MARK: Editing

    func beginEditing(_ row: Int, _ column: Int, text: String, replace: Bool) {
        let ref = CellRef(row: model.rows[row].id, column: model.columns[column].id)
        editing = (ref, nil)
        let rect = cellRect(row: row, column: column).insetBy(dx: 2, dy: 3)
        startEditor(rect, text: text, number: model.columns[column].type == .number, replace: replace)
    }

    func beginRenaming(_ fieldID: String) {
        guard let c = model.columns.firstIndex(where: { $0.id == fieldID }) else { return }
        editing = (nil, fieldID)
        let e = edges
        let rect = NSRect(x: Metrics.margin + e[c] + 2, y: Metrics.headerY + 3, width: e[c + 1] - e[c] - 4, height: Metrics.row - 6)
        startEditor(rect, text: model.name(of: fieldID), number: false, replace: false)
        editor.currentEditor()?.selectAll(nil)
    }

    private func startEditor(_ rect: NSRect, text: String, number: Bool, replace: Bool) {
        editor.stringValue = text
        editor.alignment = number ? .right : .left
        editor.frame = rect
        if editor.superview == nil { addSubview(editor) }
        window?.makeFirstResponder(editor)
        if let fe = editor.currentEditor() {
            fe.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        }
    }

    /// Commits or drops what the editor holds. Leaving the editor commits.
    func endEditing(commit: Bool) {
        guard let e = editing else { return }
        editing = nil
        let text = editor.stringValue
        editor.removeFromSuperview()
        if commit {
            if let ref = e.ref, let r = rowIndex[ref.row], let column = model.columns.first(where: { $0.id == ref.column }) {
                model.setText(r, column, text)
            } else if let id = e.header {
                model.renameField(id, text)
            }
        }
        if window?.firstResponder == nil || window?.firstResponder === window { window?.makeFirstResponder(self) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        let ref = editing?.ref
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            endEditing(commit: true)
            window?.makeFirstResponder(self)
        case #selector(NSResponder.cancelOperation(_:)):
            endEditing(commit: false)
            window?.makeFirstResponder(self)
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            endEditing(commit: true)
            window?.makeFirstResponder(self)
            if let ref, let r = rowIndex[ref.row], let c = model.columns.firstIndex(where: { $0.id == ref.column }) {
                select(r, selector == #selector(NSResponder.insertTab(_:)) ? min(model.columns.count - 1, c + 1) : max(0, c - 1))
            }
        default: return false
        }
        return true
    }

    func controlTextDidEndEditing(_ obj: Notification) { endEditing(commit: true) }

    // MARK: Menus

    func openMenu(_ items: [MenuItem], anchor: NSRect, width: CGFloat = 200) {
        guard let window else { return }
        let menu = MenuPopupView(items: items, style: .menu)
        menu.minimumWidth = width
        menu.hostPopup = PopupHost.host(for: window).open(menu, trigger: self, anchorRect: anchor,
                                                          placement: PopupPlacement(side: .bottom, align: .start, sideOffset: 4, fallbackAxisSide: .none),
                                                          swallowsOutsideClick: true, returnsFocus: false)
        popupMenu = menu
    }

    static func typeName(_ t: FieldType) -> String {
        switch t {
        case .files: "Files & media"
        case .number: "Number"
        case .checkbox: "Checkbox"
        case .select: "Select"
        case .multi: "Multi-select"
        case .date: "Date"
        case .url: "Link"
        default: "Text"
        }
    }

    static func typeIcon(_ t: FieldType?) -> IconName? {
        switch t {
        case nil, .text?: .type
        case .checkbox?: .circleCheck
        case .select?: .circleDot
        case .multi?: .tag
        case .date?: .calendar
        case .url?: .link
        case .files?: .paperclip
        default: nil
        }
    }

    private func showAddFieldMenu(anchor: NSRect) {
        let items = FieldType.allCases.map { t in
            MenuItem(Self.typeName(t), icon: Self.typeIcon(t)) { [weak self] in
                guard let self, let id = self.model.addField(t) else { return }
                DispatchQueue.main.async { self.beginRenaming(id) }
            }
        }
        openMenu(items, anchor: anchor, width: 180)
    }

    private func showHeaderMenu(_ c: Int) {
        let column = model.columns[c]
        let e = edges
        let anchor = NSRect(x: Metrics.margin + e[c], y: Metrics.headerY, width: e[c + 1] - e[c], height: Metrics.row)
        var items: [MenuItem] = []
        items.append(MenuItem("Rename", icon: .pencil) { [weak self] in DispatchQueue.main.async { self?.beginRenaming(column.id) } })
        if !column.isTitle {
            let fixed = column.id == FieldID.done || column.id == FieldID.due
            var types = FieldType.allCases.map { t in
                var item = MenuItem.radio(Self.typeName(t), checked: t == column.type) { [weak self] on in
                    guard on else { return }
                    DispatchQueue.main.async { self?.changeType(column.id, to: t) }
                }
                item.closesOnClick = true
                item.isDisabled = fixed
                return item
            }
            if fixed { types.insert(.note("Done and Due keep their type."), at: 0) }
            items.append(.submenu("Type", icon: Self.typeIcon(column.type) ?? .type, types))
            items.append(.separator)
        }
        items.append(MenuItem("Sort ascending", icon: .arrowUp) { [weak self] in self?.model.sort(by: column.id, desc: false) })
        items.append(MenuItem("Sort descending", icon: .arrowDown) { [weak self] in self?.model.sort(by: column.id, desc: true) })
        items.append(.submenu("Filter", icon: .listFilter, filterOps(column.id, anchor: anchor)))
        items.append(.separator)
        items.append(MenuItem("Hide in this view", icon: .eyeOff) { [weak self] in self?.model.setHidden(column.id, true) })
        if column.isTitle {
            items.append(.note("Every row is a page, so its title can't be deleted."))
        } else {
            items.append(MenuItem("Delete field", icon: .trash2, destructive: true) { [weak self] in self?.deleteField(column.id) })
        }
        openMenu(items, anchor: anchor, width: 200)
    }

    /// Converts in place, after a confirmation that names how many values are lost.
    func changeType(_ id: String, to type: FieldType) {
        guard let change = model.previewType(id, to: type) else { return }
        guard change.lost > 0, let window else { model.applyType(change); return }
        let name = model.name(of: id)
        let count = change.lost == 1 ? "1 value" : "\(change.lost) values"
        confirm(in: window, title: "Change \(name) to \(Self.typeName(type))?",
                message: "\(count) can't convert and will be cleared. Undo brings them back.", action: "Change type") { [weak self] in
            self?.model.applyType(change)
        }
    }

    private func confirm(in window: NSWindow, title: String, message: String, action: String, done: @escaping @MainActor () -> Void) {
        let dialog = DialogView(title: title, message: message)
        dialog.maxWidth = 400
        let cancel = ButtonView("Cancel", variant: .outline)
        let ok = ButtonView(action, variant: .destructive)
        dialog.footerButtons = [cancel, ok]
        let host = ModalHost.present(dialog, in: window)
        cancel.action = { [weak host] in host?.close() }
        dialog.onClose = { [weak host] in host?.close() }
        ok.action = { [weak host] in host?.close(); done() }
    }

    /// Asks for one line of text, for a filter value or a new option.
    private func prompt(_ title: String, placeholder: String, action: String, done: @escaping @MainActor (String) -> Void) {
        guard let window else { return }
        let dialog = DialogView(title: title)
        dialog.maxWidth = 360
        let input = InputView(placeholder: placeholder)
        dialog.panelContent = [input]
        let cancel = ButtonView("Cancel", variant: .outline)
        let ok = ButtonView(action)
        dialog.footerButtons = [cancel, ok]
        let host = ModalHost.present(dialog, in: window)
        let submit: @MainActor () -> Void = { [weak host, weak input, weak self] in
            let text = input?.text ?? ""
            host?.close()
            self?.window?.makeFirstResponder(self)
            if !text.trimmingCharacters(in: .whitespaces).isEmpty { done(text) }
        }
        cancel.action = { [weak host] in host?.close() }
        dialog.onClose = { [weak host] in host?.close() }
        ok.action = submit
        input.onSubmit = submit
        DispatchQueue.main.async { window.makeFirstResponder(input) }
    }

    /// The operators for a field, each adding a filter or asking for its value.
    private func filterOps(_ id: String, anchor: NSRect) -> [MenuItem] {
        let type = model.fields[id]?.type
        let ops = type.map(FieldFilters.operators) ?? FieldFilters.operators(for: .text)
        let name = model.name(of: id)
        return ops.map { op in
            let add: @MainActor (JSONValue) -> Void = { [weak self] v in self?.model.addFilter(Filter(field: id, op: op, value: v)) }
            switch (type, op) {
            case (_, .isEmpty), (_, .isNotEmpty), (_, .thisWeek), (_, .overdue):
                return MenuItem(op.rawValue.capitalizingFirst) { add(.null) }
            case (.checkbox?, _):
                return .submenu("Is", [MenuItem("Checked") { add(.bool(true)) }, MenuItem("Unchecked") { add(.bool(false)) }])
            case (.select?, _), (.multi?, _):
                let options = (model.fields[id]?.options ?? [:]).sorted { $0.value.order < $1.value.order }
                let items = options.isEmpty ? [MenuItem.note("No options yet")] : options.map { o in MenuItem(o.value.name) { add(.string(o.key)) } }
                return .submenu(op.rawValue.capitalizingFirst, items)
            case (.date?, _):
                return .submenu(op.rawValue.capitalizingFirst, dateChoices(anchor: anchor) { d in add(.string(d.start.rawValue)) })
            case (.number?, _):
                return MenuItem(op.rawValue + "…") { [weak self] in
                    DispatchQueue.main.async {
                        self?.prompt("\(name) \(op.rawValue)", placeholder: "A number", action: "Add filter") { text in
                            guard let n = Decimal(string: text.trimmingCharacters(in: .whitespaces), locale: Locale(identifier: "en_US_POSIX")) else { return }
                            add(.number(n))
                        }
                    }
                }
            default:
                return MenuItem(op.rawValue.capitalizingFirst + "…") { [weak self] in
                    DispatchQueue.main.async {
                        self?.prompt("\(name) \(op.rawValue)", placeholder: "Text", action: "Add filter") { add(.string($0)) }
                    }
                }
            }
        }
    }

    private func showFilterMenu() {
        var items: [MenuItem] = model.filters.enumerated().map { i, f in
            MenuItem(model.describe(f), icon: .x) { [weak self] in self?.model.removeFilter(i) }
        }
        if !items.isEmpty { items.append(.separator) }
        let anchor = filterButton.frame
        let fields = [FieldID.title] + model.fieldOrder
        items.append(.submenu("Add filter", icon: .plus, fields.map { id in
            .submenu(model.name(of: id), icon: Self.typeIcon(model.fields[id]?.type), filterOps(id, anchor: anchor))
        }))
        openMenu(items, anchor: anchor, width: 220)
    }

    private func showSortMenu() {
        var items: [MenuItem] = model.sorts.enumerated().map { i, s in
            MenuItem("\(model.name(of: s.field)) \(s.desc ? "descending" : "ascending")", icon: .x) { [weak self] in self?.model.removeSort(i) }
        }
        if !items.isEmpty { items.append(.separator) }
        let fields = [FieldID.title] + model.fieldOrder
        let full = model.sorts.count >= 3
        var add = MenuItem.submenu("Add sort", icon: .plus, fields.map { id in
            .submenu(model.name(of: id), icon: Self.typeIcon(model.fields[id]?.type), [
                MenuItem("Ascending", icon: .arrowUp) { [weak self] in self?.model.addSort(id, desc: false) },
                MenuItem("Descending", icon: .arrowDown) { [weak self] in self?.model.addSort(id, desc: true) },
            ])
        })
        add.isDisabled = full
        items.append(add)
        if full { items.append(.note("A table sorts by three fields at most.")) }
        if !model.sorts.isEmpty { items.append(MenuItem("Clear sort", icon: .x) { [weak self] in self?.model.clearSort() }) }
        openMenu(items, anchor: sortButton.frame, width: 220)
    }

    private func showFieldsMenu() {
        let shown = Set(model.columns.map(\.id))
        var items: [MenuItem] = ([FieldID.title] + model.fieldOrder).map { id in
            .checkbox(model.name(of: id), checked: shown.contains(id)) { [weak self] on in self?.model.setHidden(id, !on) }
        }
        if !items.isEmpty { items.append(.separator) }
        items.append(.submenu("New field", icon: .plus, FieldType.allCases.map { t in
            MenuItem(Self.typeName(t), icon: Self.typeIcon(t)) { [weak self] in
                guard let self, let id = self.model.addField(t) else { return }
                DispatchQueue.main.async { self.beginRenaming(id) }
            }
        }))
        openMenu(items, anchor: fieldsButton.frame, width: 220)
    }

    private func showOptionsMenu(_ row: Int, _ column: SpaceTableModel.Column, anchor: NSRect) {
        let id = model.rows[row].id
        let field = model.fields[column.id]
        let options = (field?.options ?? [:]).sorted { $0.value.order == $1.value.order ? $0.key < $1.key : $0.value.order < $1.value.order }
        var picked = Set<String>()
        switch model.rows[row].page.props[column.id] {
        case .string(let s)?: picked = [s]
        case .multi(let ids)?: picked = Set(ids)
        default: break
        }
        let multi = column.type == .multi
        var items: [MenuItem] = options.map { o in
            var item: MenuItem = multi
                ? .checkbox(o.value.name, checked: picked.contains(o.key)) { [weak self] _ in self?.withRow(id) { self?.model.toggleOption($0, column, o.key) } }
                : .radio(o.value.name, checked: picked.contains(o.key)) { [weak self] _ in self?.withRow(id) { self?.model.toggleOption($0, column, o.key) } }
            if !multi { item.closesOnClick = true }
            let color = SpaceTableColors.text(o.value.color)
            item.leading = { SpaceTableDot(color: color) }
            item.leadingSize = 8
            return item
        }
        if !items.isEmpty { items.append(.separator) }
        items.append(MenuItem("New option…", icon: .plus) { [weak self] in
            DispatchQueue.main.async {
                self?.prompt("New option in \(column.name)", placeholder: "Name", action: "Add") { name in
                    self?.withRow(id) { self?.model.addOption(name, to: column, pickFor: $0) }
                }
            }
        })
        if !picked.isEmpty { items.append(MenuItem("Clear", icon: .x) { [weak self] in self?.withRow(id) { self?.model.setValue($0, column, nil) } }) }
        openMenu(items, anchor: anchor, width: max(180, anchor.width))
    }

    private func withRow(_ id: PageID, _ body: (Int) -> Void) { if let i = rowIndex[id] { body(i) } }

    func showDateMenu(_ row: Int, _ column: SpaceTableModel.Column, anchor: NSRect) {
        let id = model.rows[row].id
        var items = dateChoices(anchor: anchor) { [weak self] d in self?.withRow(id) { self?.model.setValue($0, column, .date(d)) } }
        if model.rows[row].page.props[column.id] != nil {
            items.append(.separator)
            if let due = date(id, column) {
                items += SpaceReminderDialog.menuItems(due, open: { [weak self] in
                    guard let self, let window = self.window, let due = self.date(id, column) else { return }
                    SpaceReminderDialog.present(in: window, due: due, current: { [weak self] in self?.date(id, column) }) { [weak self] d in
                        self?.withRow(id) { self?.model.setValue($0, column, .date(d)) }
                    }
                }, set: { [weak self] d in self?.withRow(id) { self?.model.setValue($0, column, .date(d)) } })
            }
            items.append(MenuItem("Remove date", icon: .x) { [weak self] in self?.withRow(id) { self?.model.setValue($0, column, nil) } })
        }
        openMenu(items, anchor: anchor, width: 180)
    }

    /// The row's value in a date column, if it holds one.
    private func date(_ id: PageID, _ column: SpaceTableModel.Column) -> DateValue? {
        guard let i = rowIndex[id], case .date(let d)? = model.rows[i].page.props[column.id] else { return nil }
        return d
    }

    /// Today, Tomorrow, Next week and a calendar, as date-only values in the device's zone.
    private func dateChoices(anchor: NSRect, _ pick: @escaping @MainActor (DateValue) -> Void) -> [MenuItem] {
        let zone = model.timeZone()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let now = model.now()
        func day(_ offset: Int) -> DateValue? {
            guard let date = calendar.date(byAdding: .day, value: offset, to: now), let point = try? DatePoint.from(date, in: zone, timed: false) else { return nil }
            return try? DateValue(start: point)
        }
        let weekday = calendar.component(.weekday, from: now)
        let toMonday = (9 - weekday) % 7 == 0 ? 7 : (9 - weekday) % 7
        return [
            MenuItem("Today", icon: .calendar) { if let d = day(0) { pick(d) } },
            MenuItem("Tomorrow", icon: .calendarArrowUp) { if let d = day(1) { pick(d) } },
            MenuItem("Next week", icon: .calendarClock) { if let d = day(toMonday) { pick(d) } },
            MenuItem("Pick a date…", icon: .calendarArrowDown) { [weak self] in
                DispatchQueue.main.async { self?.openCalendar(anchor: anchor, pick) }
            },
        ]
    }

    /// The Redesign calendar in a popover under the cell, as the page editor's Pick a date… opens it.
    private func openCalendar(anchor: NSRect, _ pick: @escaping @MainActor (DateValue) -> Void) {
        guard let window else { return }
        let zone = model.timeZone()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let today = calendar.dateComponents([.year, .month, .day], from: model.now())
        let view = CalendarView(month: today, selected: nil, today: today)
        view.setAccessibilityLabel("Date")
        let popover = PopoverView(content: view, padding: .compact)
        let host = PopupHost.host(for: window)
        let open = host.open(popover, trigger: self, anchorRect: anchor,
                             placement: PopupPlacement(side: .bottom, align: .start, sideOffset: 4, fallbackAxisSide: .none),
                             motion: .popover, swallowsOutsideClick: true, returnsFocus: false)
        view.onSelect = { [weak host] parts in
            host?.close(open, returnFocus: false)
            guard let date = calendar.date(from: parts), let point = try? DatePoint.from(date, in: zone, timed: false),
                  let d = try? DateValue(start: point) else { return }
            pick(d)
        }
    }
}

/// One visible row: dividers only, a hover fill, and each cell drawn from the model.
final class SpaceTableRowView: DSView {
    weak var doc: SpaceTableDocument?
    var index = 0
    override var wantsUpdateLayer: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let doc, doc.model.rows.indices.contains(index) else { return }
        let model = doc.model
        let item = model.rows[index]
        if doc.hoverRow == index {
            Themed.color(\.foreground, 0.04).setFill()
            let fill = NSRect(x: 0, y: 1, width: bounds.width - SpaceTableDocument.Metrics.addColumn, height: bounds.height - 2)
            NSBezierPath(roundedRect: fill, xRadius: 6, yRadius: 6).fill()
            if model.canReorder {
                SpaceTableCellDrawing.icon(.gripVertical, in: CGRect(x: -18, y: bounds.midY - 7, width: 14, height: 14), color: Themed.color(\.iconMuted))
            }
        }
        Themed.color(\.border, 0.6).setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width - SpaceTableDocument.Metrics.addColumn, height: 1).fill()
        let edges = doc.edges
        for (c, column) in model.columns.enumerated() {
            let rect = NSRect(x: edges[c], y: 0, width: edges[c + 1] - edges[c], height: bounds.height)
            guard rect.intersects(dirtyRect) else { continue }
            var content = rect
            if column.isTitle {
                if SpacePageIcon.draw(item.page, in: SpaceTableCellDrawing.iconRect(in: rect)) {
                    content.origin.x += 22
                    content.size.width -= 22
                } else if doc.hoverRow == index, rect.width > 120 {
                    SpaceTableCellDrawing.icon(.smilePlus, in: SpaceTableCellDrawing.addIconRect(in: rect).insetBy(dx: 2, dy: 2), color: Themed.color(\.iconMuted))
                    content.size.width -= 28
                }
            }
            SpaceTableCellDrawing.draw(model.cell(index, column), column: column, in: content)
            if doc.selection == .init(row: item.id, column: column.id) {
                SpacePageMetrics.accent.setStroke()
                let ring = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 2), xRadius: 4, yRadius: 4)
                ring.lineWidth = 1.5
                ring.stroke()
            }
        }
    }
}

@MainActor
enum SpaceTableCellDrawing {
    static let pad: CGFloat = 10
    /// One CoreText line, truncated with an ellipsis, centered on the rect's middle. CoreText skips the layout
    /// manager that NSString drawing builds per call, which made a row cost about 1 ms.
    static func text(_ s: String, in rect: NSRect, color: NSColor, font: NSFont = DSFont.ui(13), align: NSTextAlignment = .left, pad: CGFloat = pad) {
        guard let context = NSGraphicsContext.current?.cgContext, !s.isEmpty else { return }
        let width = rect.width - 2 * pad
        guard width > 6 else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor]
        var line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
        if CTLineGetTypographicBounds(line, nil, nil, nil) > width,
           let short = CTLineCreateTruncatedLine(line, width, .end, CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attrs))) {
            line = short
        }
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let w = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        let x = align == .right ? rect.maxX - pad - w : rect.minX + pad
        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: x, y: (rect.midY + (ascent - descent) / 2).rounded())
        CTLineDraw(line, context)
        context.restoreGState()
    }

    static func draw(_ cell: SpaceTableModel.Cell, column: SpaceTableModel.Column, in rect: NSRect) {
        switch cell {
        case .empty: break
        case .text(let s): text(s, in: rect, color: column.isTitle ? Themed.color(\.foreground) : Themed.color(\.mutedForeground),
                                font: column.isTitle ? DSFont.ui(13, weight: .medium) : DSFont.ui(13))
        case .link(let s): text(s, in: rect, color: SpacePageMetrics.accent)
        case .number(let s): text(s, in: rect, color: Themed.color(\.foreground), font: DSFont.ui(13).withMonospacedDigits(), align: .right)
        case .date(let s, let overdue): text(s, in: rect, color: overdue ? Themed.color(\.destructive) : Themed.color(\.foreground))
        case .files(let refs): drawFiles(refs, in: rect)
        case .checkbox(let on):
            if on { SpaceBlockFragment.drawCheckbox(CGRect(x: rect.minX + pad, y: rect.midY - 8, width: 16, height: 16), on: true) }
            else { emptyBox(CGRect(x: rect.minX + pad, y: rect.midY - 8, width: 16, height: 16)) }
        case .options(let options):
            var x = rect.minX + pad
            let font = DSFont.ui(12, weight: .medium)
            for o in options {
                let natural = CTLineGetTypographicBounds(CTLineCreateWithAttributedString(NSAttributedString(string: o.name, attributes: [.font: font])), nil, nil, nil)
                let w = min(natural.rounded(.up) + 12, rect.maxX - pad - x)
                guard w > 16 else { break }
                let pill = NSRect(x: x, y: rect.midY - 10, width: w, height: 20)
                SpaceTableColors.fill(o.color).setFill()
                NSBezierPath(roundedRect: pill, xRadius: 4, yRadius: 4).fill()
                text(o.name, in: pill, color: SpaceTableColors.text(o.color), font: font, pad: 6)
                x += w + 4
            }
        }
        // An empty checkbox cell still shows its box, so one click visibly ticks it.
        if cell == .empty, column.type == .checkbox { emptyBox(CGRect(x: rect.minX + pad, y: rect.midY - 8, width: 16, height: 16)) }
    }

    /// SpacePageIcons renders a layer, which draws upside down in a flipped view's own `draw(_:)`.
    static func icon(_ name: IconName, in rect: CGRect, color: NSColor) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.translateBy(x: 0, y: rect.minY * 2 + rect.height)
        context.scaleBy(x: 1, y: -1)
        SpacePageIcons.draw(name, in: rect, color: color)
        context.restoreGState()
    }

    static func emptyBox(_ r: CGRect) {
        Themed.color(\.mutedForeground, 0.6).setStroke()
        let path = NSBezierPath(roundedRect: r.insetBy(dx: 0.75, dy: 0.75), xRadius: 4, yRadius: 4)
        path.lineWidth = 1.5
        path.stroke()
    }
}

/// The nine option colors (docs/space.md "Fields"), as tinted pills from mockup look A. Tailwind 700 and 300 text
/// over the 500 at low alpha; DesignSystem's base palette carries only some of those steps, so they're fixed here.
@MainActor
enum SpaceTableColors {
    private static let table: [FieldColor: (light: UInt32, dark: UInt32, base: UInt32)] = [
        .gray: (0x52525b, 0xd4d4d8, 0x71717a), .brown: (0x7c4a2a, 0xd9b38c, 0x9a6a44),
        .orange: (0xc2410c, 0xfdba74, 0xf97316), .yellow: (0xa16207, 0xfde047, 0xeab308),
        .green: (0x047857, 0x6ee7b7, 0x10b981), .blue: (0x1d4ed8, 0x93c5fd, 0x3b82f6),
        .purple: (0x6d28d9, 0xc4b5fd, 0x8b5cf6), .pink: (0xbe185d, 0xf9a8d4, 0xec4899),
        .red: (0xb91c1c, 0xfca5a5, 0xef4444),
    ]
    private static var cache: [String: NSColor] = [:]
    private static func rgb(_ v: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(v >> 16 & 0xff) / 255, green: CGFloat(v >> 8 & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: alpha)
    }
    private static func dynamic(_ key: String, _ light: NSColor, _ dark: NSColor) -> NSColor {
        if let c = cache[key] { return c }
        let c = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
        cache[key] = c
        return c
    }
    static func text(_ c: FieldColor) -> NSColor {
        let t = table[c] ?? table[.gray]!
        return dynamic("t" + c.rawValue, rgb(t.light), rgb(t.dark))
    }
    static func fill(_ c: FieldColor) -> NSColor {
        let t = table[c] ?? table[.gray]!
        return dynamic("f" + c.rawValue, rgb(t.base, 0.14), rgb(t.base, 0.22))
    }
}

/// A color dot for option rows in menus.
final class SpaceTableDot: DSView {
    let color: NSColor
    init(color: NSColor) {
        self.color = color
        super.init(frame: NSRect(x: 0, y: 0, width: 8, height: 8))
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func updateLayer() {
        layer?.cornerRadius = bounds.width / 2
        layer?.backgroundColor = color.cgColor(in: self)
    }
}

/// Column names with look A's type icons, the sort arrow and the last "+".
final class SpaceTableHeaderRow: DSView {
    weak var doc: SpaceTableDocument?
    override var wantsUpdateLayer: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let doc else { return }
        let edges = doc.edges
        let muted = Themed.color(\.mutedForeground)
        let icon = Themed.color(\.iconMuted)
        for (c, column) in doc.model.columns.enumerated() {
            let rect = NSRect(x: edges[c], y: 0, width: edges[c + 1] - edges[c], height: bounds.height)
            var x = rect.minX + SpaceTableCellDrawing.pad
            if let name = SpaceTableDocument.typeIcon(column.type) {
                SpaceTableCellDrawing.icon(name, in: CGRect(x: x, y: rect.midY - 6.5, width: 13, height: 13), color: icon)
            } else {
                SpaceTableCellDrawing.text("#", in: NSRect(x: x + 1, y: rect.minY, width: 14, height: rect.height), color: icon, font: DSFont.ui(12, weight: .medium), pad: 0)
            }
            x += 19
            var labelRect = NSRect(x: x - SpaceTableCellDrawing.pad, y: 0, width: rect.maxX - x, height: rect.height)
            if let sort = doc.model.sorts.first(where: { $0.field == column.id }) {
                labelRect.size.width -= 16
                SpaceTableCellDrawing.icon(sort.desc ? .arrowDown : .arrowUp, in: CGRect(x: rect.maxX - 22, y: rect.midY - 6, width: 12, height: 12), color: icon)
            }
            SpaceTableCellDrawing.text(column.name, in: labelRect, color: muted, font: DSFont.ui(12, weight: .medium))
        }
        let plus = edges.last ?? 0
        SpaceTableCellDrawing.icon(.plus, in: CGRect(x: plus + 11, y: bounds.midY - 7, width: 14, height: 14), color: icon)
        Themed.color(\.border).setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }
}

/// "+ New" under the last row.
final class SpaceTableNewRow: DSView {
    weak var doc: SpaceTableDocument?
    var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }
    override var wantsUpdateLayer: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let color = hovered ? Themed.color(\.mutedForeground) : Themed.color(\.placeholder)
        if hovered {
            Themed.color(\.foreground, 0.04).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
        SpaceTableCellDrawing.icon(.plus, in: CGRect(x: 10, y: bounds.midY - 7, width: 14, height: 14), color: color)
        NSAttributedString(string: "New", attributes: [.font: DSFont.ui(13), .foregroundColor: color]).draw(at: NSPoint(x: 30, y: bounds.midY - 9))
    }
}

/// Filter, Sort and Fields: quiet until hovered, brighter while one is on.
final class SpaceTableToolButton: DSView {
    var onPress: () -> Void = {}
    var isActive = false { didSet { if isActive != oldValue { restyle() } } }
    var badge: String? { didSet { if badge != oldValue { label.text = badge.map { "\(title) \($0)" } ?? title; invalidateIntrinsicContentSize(); restyle() } } }
    private let title: String
    private var hovering = false { didSet { restyle() } }
    private let icon: IconView
    private let label: LabelView

    init(title: String, icon name: IconName) {
        self.title = title
        icon = IconView(name: name, size: 14, strokeColor: Themed.color(\.mutedForeground))
        label = LabelView(title, font: DSFont.ui(12, weight: .medium), color: Themed.color(\.mutedForeground))
        super.init(frame: .zero)
        label.lineHeight = 16
        addSubview(icon)
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 8 + 14 + 6 + label.textWidth.rounded(.up) + 8, height: 26) }

    private func restyle() {
        let color = isActive || hovering ? Themed.color(\.foreground) : Themed.color(\.mutedForeground)
        label.color = color
        icon.strokeColor = color
        needsDisplay = true
    }

    override func updateLayer() {
        layer?.cornerRadius = 6
        layer?.backgroundColor = hovering ? Themed.color(\.foreground, 0.05).cgColor(in: self) : NSColor.clear.cgColor
    }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 8, y: (bounds.height - 14) / 2, width: 14, height: 14)
        label.frame = NSRect(x: 28, y: (bounds.height - 16) / 2, width: bounds.width - 28 - 8, height: 16)
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { onPress() }
    override func accessibilityPerformPress() -> Bool { onPress(); return true }
}

/// The in-cell text editor: borderless, on the theme's background, inside the selection ring.
final class SpaceTableCellEditor: NSTextField {
    init() {
        super.init(frame: .zero)
        isBordered = false
        drawsBackground = true
        focusRingType = .none
        font = DSFont.ui(13)
        cell?.usesSingleLineMode = true
        cell?.isScrollable = true
        cell?.wraps = false
        setAccessibilityLabel("Cell")
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        backgroundColor = Themed.color(\.background)
        textColor = Themed.color(\.foreground)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        backgroundColor = Themed.color(\.background)
        textColor = Themed.color(\.foreground)
    }
}

private extension String {
    var capitalizingFirst: String { prefix(1).uppercased() + dropFirst() }
}
