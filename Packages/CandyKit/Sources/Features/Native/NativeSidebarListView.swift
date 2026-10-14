import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// Glass Native's thread list (docs/glass-native.md phase 2): a view-based source list `NSTableView` with T3 Code
/// desktop's rows in T3's order. It takes the same items and `SidebarListCache` patches as `SidebarListView`. A
/// change to one thread reconfigures that row's cell in place, and only labels whose text changed are set.
final class NativeSidebarListView: NSScrollView, SidebarItemsPresenting, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    let table = NativeSidebarTableView()
    private(set) var items: [SidebarItem] = []
    /// Display row to index in `items`, and back.
    /// Per row: the item's key and height, kept so an update doesn't recompute them for every row.
    private var keys: [String] = []
    private var heights: [CGFloat] = []
    private(set) var itemsGeneration: Int?
    var nowMs: Int64 = 0

    var actions = SidebarActions()
    var onOpen: ((ThreadId) -> Void)?
    var onToggleShelf: ((SidebarShelf) -> Void)?
    var onShowMore: (() -> Void)?
    var onOpenDraft: ((String) -> Void)?
    var onOpenSearchResult: ((ThreadId) -> Void)?
    var onVisibleRowsChange: (() -> Void)?
    /// Arrow keys or Shift-arrows picked rows: the thread ids, for the multi-selection.
    var onKeyboardSelection: (([ThreadId]) -> Void)?
    var onRenameCommit: ((ThreadId, String, String) -> Void)?
    var onRenameCancel: (() -> Void)?
    var hoverCard: ((ThreadId) -> SidebarThreadHoverCardModel?)?
    var settlementSupported: () -> Bool = { true }
    var snoozeSupported: () -> Bool = { true }
    var canSortThread: (ThreadId) -> Bool = { _ in false }
    var canSortDrop: (ThreadId, SidebarSection, SidebarDropTarget) -> Bool = { _, _, _ in false }
    var onSortDrop: (ThreadId, SidebarSection, SidebarDropTarget) -> Void = { _, _, _ in }

    /// Counters for tests: cells made and configure calls.
    private(set) var createdCells = 0
    private(set) var configureCount = 0
    /// Set while the list moves the table's selection itself, so that doesn't read as the user's.
    private var syncingSelection = false
    private var clipObserver: NSObjectProtocol?

    override init(frame: NSRect) {
        super.init(frame: frame)
        drawsBackground = false
        // The list sits below the search row, clear of the toolbar; no automatic inset pushes or hides rows.
        automaticallyAdjustsContentInsets = false
        hasVerticalScroller = true
        autohidesScrollers = true
        borderType = .noBorder
        let column = NSTableColumn(identifier: .init("thread"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        // Plain, with T3's fills drawn by `NativeSidebarRowView`: the source list style insets rows by its own
        // amount and paints the blue emphasized selection.
        table.style = .plain
        table.selectionHighlightStyle = .none
        table.rowSizeStyle = .custom
        table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.focusRingType = .none
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        table.list = self
        table.registerForDraggedTypes([.fileURL, .sidebarThreads])
        table.setDraggingSourceOperationMask([.move, .copy, .generic], forLocal: true)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.draggingDestinationFeedbackStyle = .gap
        documentView = table
        contentView.postsBoundsChangedNotifications = true
        clipObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.closeHoverCard()
                self?.hoverFillFollowsPointer()
                self?.onVisibleRowsChange?()
            }
        }
        setAccessibilityLabel("Threads")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    isolated deinit {
        if let clipObserver { NotificationCenter.default.removeObserver(clipObserver) }
        hoverWork?.cancel()
    }

    /// The one column always spans the table, whatever width the list was made at (the source list style adds its own insets).
    override func tile() {
        super.tile()
        table.sizeLastColumnToFit()
    }

    // MARK: Data

    func item(atRow row: Int) -> SidebarItem? { items.indices.contains(row) ? items[row] : nil }

    /// Replaces the items. Same rows in the same order reconfigure in place; otherwise rows that came or went fade,
    /// or the table reloads when too much moved.
    func setItems(_ new: [SidebarItem], animated: Bool, generation: Int?) {
        itemsGeneration = generation
        let oldItems = items, oldKeys = keys
        let newKeys = new.map(\.key)
        let oldHeights = heights
        items = new
        keys = newKeys
        heights = new.map(height)
        if oldKeys == newKeys {
            // `refresh` can't see a height change once `heights` holds the new ones, so note them here.
            let resized = IndexSet(new.indices.filter { oldHeights.indices.contains($0) && oldHeights[$0] != heights[$0] })
            if !resized.isEmpty { table.noteHeightOfRows(withIndexesChanged: resized) }
            for row in new.indices where oldItems[row] != new[row] {
                refresh(row: row, old: oldItems[row])
            }
        } else if !oldKeys.isEmpty, let (removed, inserted) = Self.rowChanges(from: oldKeys, to: newKeys) {
            // Rows came or went (a shelf opening, a thread settling): only those rows change, and the rows that
            // stay keep their cells. A handful fade; a whole shelf appears at once.
            let fade = animated && window != nil && removed.count + inserted.count <= 60
            let oldRow = Dictionary(oldKeys.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
            table.beginUpdates()
            table.removeRows(at: removed, withAnimation: fade ? .effectFade : [])
            table.insertRows(at: inserted, withAnimation: fade ? .effectFade : [])
            table.endUpdates()
            var resized = IndexSet()
            for row in new.indices where !inserted.contains(row) {
                guard let index = oldRow[newKeys[row]] else { continue }
                if oldHeights.indices.contains(index), oldHeights[index] != heights[row] { resized.insert(row) }
                guard oldItems[index] != new[row] else { continue }
                refresh(row: row, old: oldItems[index])
            }
            if !resized.isEmpty { table.noteHeightOfRows(withIndexesChanged: resized) }
        } else {
            // Too much moved (a new scope, a search): the table loads only the rows on screen.
            closeHoverCard()
            table.reloadData()
        }
        syncSelection()
    }

    /// The rows to remove (old indices) and insert (new indices) to turn `old` into `new`, nil when a reload is
    /// cheaper. The common head and tail are skipped first, so a shelf of 1,400 rows opening costs one pass; what is
    /// left is diffed only while it is small.
    static func rowChanges(from old: [String], to new: [String]) -> (removed: IndexSet, inserted: IndexSet)? {
        var head = 0
        while head < old.count, head < new.count, old[head] == new[head] { head += 1 }
        var tail = 0
        while tail < old.count - head, tail < new.count - head, old[old.count - 1 - tail] == new[new.count - 1 - tail] { tail += 1 }
        let oldMiddle = old[head..<(old.count - tail)], newMiddle = new[head..<(new.count - tail)]
        if oldMiddle.isEmpty || newMiddle.isEmpty {
            return (IndexSet(oldMiddle.indices), IndexSet(newMiddle.indices))
        }
        guard oldMiddle.count <= 120, newMiddle.count <= 120 else { return nil }
        var removed = IndexSet(), inserted = IndexSet()
        for change in newMiddle.difference(from: oldMiddle) {
            switch change {
            case .remove(let offset, _, _): removed.insert(head + offset)
            case .insert(let offset, _, _): inserted.insert(head + offset)
            }
        }
        return removed.count + inserted.count <= 120 ? (removed, inserted) : nil
    }

    /// Single rows that kept their place, from `SidebarListCache.patch` (indices into `items`). A selection change
    /// arrives here too, so only these rows' selection is looked at.
    func patchItems(_ patch: [(index: Int, item: SidebarItem)]) -> Bool {
        for (i, item) in patch { guard i < items.count, item.key == items[i].key else { return false } }
        var select = IndexSet(), deselect = IndexSet()
        for (i, item) in patch where items[i] != item {
            let old = items[i]
            items[i] = item
            let row = i
            refresh(row: row, old: old)
            if Self.showsSelected(item) { select.insert(row) } else { deselect.insert(row) }
        }
        let current = table.selectedRowIndexes
        if !select.isSubset(of: current) || !deselect.intersection(current).isEmpty {
            syncingSelection = true
            for row in deselect where current.contains(row) { table.deselectRow(row) }
            table.selectRowIndexes(select, byExtendingSelection: true)
            syncingSelection = false
        }
        return true
    }

    /// One row's item changed: its cell reconfigures if it shows, and its height is noted if it moved.
    private func refresh(row: Int, old: SidebarItem) {
        guard let item = item(atRow: row) else { return }
        let h = height(item)
        if heights[row] != h {
            heights[row] = h
            table.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
        }
        if Self.identifier(old) != Self.identifier(item) {
            table.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
        } else if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? NativeSidebarCell {
            configure(cell, item)
        }
    }

    private func configure(_ cell: NativeSidebarCell, _ item: SidebarItem) {
        configureCount += 1
        cell.configure(item, list: self)
        if case .row(let r) = item, r.isRenaming { lendRenameField(to: cell, r) } else if renameField.superview === cell { renameField.removeFromSuperview() }
    }

    /// The table shows the active thread and the multi-selection as its selection; the search highlight in search.
    private func syncSelection() {
        var rows = IndexSet()
        for (row, item) in items.enumerated() where Self.showsSelected(item) { rows.insert(row) }
        guard table.selectedRowIndexes != rows else { return }
        syncingSelection = true
        table.selectRowIndexes(rows, byExtendingSelection: false)
        syncingSelection = false
    }

    /// The active thread, a multi-selected thread, the open draft or the search highlight.
    static func showsSelected(_ item: SidebarItem) -> Bool {
        switch item {
        case .row(let r): r.isActive || r.isSelected
        case .draft(let d): d.isActive
        case .searchResult(let r): r.isHighlighted
        default: false
        }
    }

    var visibleRowModels: [SidebarRowModel] {
        let range = table.rows(in: table.visibleRect)
        guard range.length > 0 else { return [] }
        return (range.location..<range.location + range.length).compactMap { if case .row(let r)? = item(atRow: $0) { r } else { nil } }
    }

    func scrollItemToVisible(_ key: String) {
        if let row = keys.firstIndex(of: key) { table.scrollRowToVisible(row) }
    }

    var topVisibleKey: String? {
        let range = table.rows(in: table.visibleRect)
        return range.length > 0 && keys.indices.contains(range.location) ? keys[range.location] : nil
    }

    func scrollItemToTop(_ key: String) {
        guard let row = keys.firstIndex(of: key) else { return }
        table.scroll(table.rect(ofRow: row).origin)
    }

    func rowIndex(_ id: ThreadId) -> Int? {
        keys.firstIndex(of: "thread:\(id.rawValue)")
    }

    func height(_ item: SidebarItem) -> CGFloat { NativeSidebarMetrics.height(item) }

    /// Re-applies the clock to on-screen Working durations without rebuilding anything.
    func tickWorkingRows() {
        let range = table.rows(in: table.visibleRect)
        for row in range.location..<(range.location + range.length) {
            (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? NativeThreadCardCell)?.tick()
        }
    }

    // MARK: NSTableViewDataSource and delegate

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { heights.indices.contains(row) ? heights[row] : 1 }

    private static func identifier(_ item: SidebarItem) -> NSUserInterfaceItemIdentifier {
        switch item {
        case .row(let r): .init(r.variant == .card ? "card" : "slim")
        case .shelfHeader: .init("shelf")
        case .draft: .init("draft")
        case .searchResult: .init("search")
        case .showMore, .emptyText, .noProjects, .draftDivider: .init("text")
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let item = item(atRow: row) else { return nil }
        let id = Self.identifier(item)
        let cell: NativeSidebarCell
        if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? NativeSidebarCell {
            cell = reused
        } else {
            createdCells += 1
            switch id.rawValue {
            case "card": cell = NativeThreadCardCell(frame: .zero)
            case "slim": cell = NativeThreadSlimCell(frame: .zero)
            case "shelf": cell = NativeShelfHeaderCell(frame: .zero)
            case "draft": cell = NativeDraftCell(frame: .zero)
            case "search": cell = NativeSearchResultCell(frame: .zero)
            default: cell = NativeTextCell(frame: .zero)
            }
            cell.identifier = id
        }
        configure(cell, item)
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = tableView.makeView(withIdentifier: Self.rowViewId, owner: nil) as? NativeSidebarRowView ?? {
            let made = NativeSidebarRowView(frame: .zero)
            made.identifier = Self.rowViewId
            return made
        }()
        switch item(atRow: row) {
        case .emptyText?, .noProjects?, .draftDivider?: view.fills = false
        default: view.fills = true
        }
        view.isHovered = row == hoverRow
        return view
    }

    private static let rowViewId = NSUserInterfaceItemIdentifier("row")

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        switch item(atRow: row) {
        case .row?, .draft?, .searchResult?: true
        default: false
        }
    }

    func tableView(_ tableView: NSTableView, selectionIndexesForProposedSelection proposed: IndexSet) -> IndexSet {
        IndexSet(proposed.filter { self.tableView(tableView, shouldSelectRow: $0) })
    }

    /// Arrow keys move the selection natively; the thread under it opens, as T3's list opens a focused row on Enter.
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !syncingSelection, NSApp.currentEvent?.type == .keyDown else { return }
        let rows = table.selectedRowIndexes
        if rows.count == 1, let item = item(atRow: rows.first!) {
            open(item)
            // Opening a thread focuses its composer; arrows keep walking the list, as in Mail.
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.table.window else { return }
                window.makeFirstResponder(self.table)
            }
        } else if rows.count > 1 {
            onKeyboardSelection?(rows.compactMap { if case .row(let r)? = item(atRow: $0) { r.id } else { nil } })
        }
    }

    @objc func rowClicked() {
        let row = table.clickedRow
        guard row >= 0, let item = item(atRow: row) else { return }
        open(item)
    }

    func open(_ item: SidebarItem) {
        switch item {
        case .row(let r): onOpen?(r.id)
        case .shelfHeader(let shelf, _, _): onToggleShelf?(shelf)
        case .showMore: onShowMore?()
        case .draft(let d): onOpenDraft?(d.id)
        case .searchResult(let r): onOpenSearchResult?(r.id)
        case .noProjects: actions.addProject()
        case .draftDivider, .emptyText: break
        }
    }

    @objc func addProjectPressed() { actions.addProject() }

    // MARK: Swipe actions (home/thread-swipe-actions.tsx)

    func tableView(_ tableView: NSTableView, rowActionsForRow row: Int, edge: NSTableView.RowActionEdge) -> [NSTableViewRowAction] {
        guard edge == .trailing, case .row(let r)? = item(atRow: row) else { return [] }
        return NativeSidebarRules.swipeActions(r, settlement: settlementSupported(), snooze: snoozeSupported()).map { kind in
            let action = NSTableViewRowAction(style: kind == .archive ? .destructive : .regular, title: kind.title) { [weak self] _, row in
                self?.perform(kind, r.id, row: row)
            }
            action.image = NSImage(systemSymbolName: kind.symbol, accessibilityDescription: kind.title)
            switch kind {
            case .settle: action.backgroundColor = .systemGreen
            case .snooze, .wake: action.backgroundColor = .systemIndigo
            case .unsettle: action.backgroundColor = .systemGray
            case .archive: break
            }
            return action
        }
    }

    func perform(_ kind: NativeSidebarRules.Swipe, _ id: ThreadId, row: Int) {
        table.rowActionsVisible = false
        switch kind {
        case .settle: actions.settle(id)
        case .snooze:
            let anchor = table.rowView(atRow: row, makeIfNecessary: false) ?? table
            actions.snooze(id, anchor)
        case .unsettle: actions.unsettle(id)
        case .wake: actions.unsnooze(id)
        case .archive: actions.archive(id)
        }
    }

    // MARK: Context menu

    func menu(for event: NSEvent, row: Int) -> NSMenu? {
        switch item(atRow: row) {
        case .row(let r)?:
            actions.contextMenu(r.id, event, table)
            return nil
        case .draft(let d)?:
            let menu = NSMenu()
            let discard = NSMenuItem(title: "Discard draft", action: #selector(discardDraft(_:)), keyEquivalent: "")
            discard.target = self
            discard.representedObject = d.id
            menu.addItem(discard)
            return menu
        default: return nil
        }
    }

    @objc private func discardDraft(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { actions.discardDraft(id) }
    }

    // MARK: Rename

    private lazy var renameField: NSTextField = {
        let field = NSTextField(string: "")
        field.font = SB.font(14)
        field.delegate = self
        field.focusRingType = .default
        field.bezelStyle = .roundedBezel
        return field
    }()
    private var renaming: (id: ThreadId, original: String)?
    private var renameCancelled = false

    private func lendRenameField(to cell: NativeSidebarCell, _ r: SidebarRowModel) {
        if renaming?.id != r.id {
            renaming = (r.id, r.title)
            renameField.stringValue = r.title
        }
        let frame = (cell as? NativeThreadCardCell)?.titleFrame ?? (cell as? NativeThreadSlimCell)?.titleFrame ?? cell.bounds
        if renameField.superview !== cell { cell.addSubview(renameField) }
        renameField.frame = NSRect(x: frame.minX - 2, y: frame.minY - 2, width: frame.width + 4, height: 22)
    }

    /// The row's title turns into a field holding the title, selected.
    func beginRename(_ id: ThreadId) {
        guard let row = rowIndex(id) else { return }
        table.scrollRowToVisible(row)
        if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? NativeSidebarCell, let item = item(atRow: row) { configure(cell, item) }
        renameCancelled = false
        window?.makeFirstResponder(renameField)
        renameField.currentEditor()?.selectAll(nil)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === renameField else { return false }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            renameCancelled = true
            window?.makeFirstResponder(table)
            return true
        }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            window?.makeFirstResponder(table)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let renaming else { return }
        self.renaming = nil
        renameField.removeFromSuperview()
        if renameCancelled { onRenameCancel?() } else { onRenameCommit?(renaming.id, renameField.stringValue, renaming.original) }
    }

    // MARK: Hover card (Sidebar.tsx:1966-2216: delay 150 ms, timeout 400 ms, right of the row)

    private var hoverWork: DispatchWorkItem?
    private var hoverPopup: (id: ThreadId, popup: OpenPopup)?
    private var hoverClosedAt: Date?
    private var hoverRow = -1

    func hover(row: Int) {
        guard row != hoverRow else { return }
        setHoverFill(from: hoverRow, to: row)
        hoverRow = row
        hoverWork?.cancel()
        let id: ThreadId? = switch item(atRow: row) {
        case .row(let r)?: r.isRenaming ? nil : r.id
        case .searchResult(let r)?: r.id
        default: nil
        }
        guard let id else { closeHoverCard(); return }
        if hoverPopup?.id == id { return }
        let instant = hoverClosedAt.map { Date().timeIntervalSince($0) < 0.4 } ?? false
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.hoverRow == row else { return }
                self.showHoverCard(id, row: row, instant: instant)
            }
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (instant ? 0 : 0.15), execute: work)
    }

    /// After a scroll the pointer rests over another row: the fill moves there, the hover card stays shut.
    private func hoverFillFollowsPointer() {
        guard hoverRow >= 0, let window else { return }
        let row = table.row(at: table.convert(window.mouseLocationOutsideOfEventStream, from: nil))
        guard row != hoverRow else { return }
        setHoverFill(from: hoverRow, to: row)
        hoverRow = row
    }

    private func setHoverFill(from old: Int, to new: Int) {
        for (row, on) in [(old, false), (new, true)] where row >= 0 && row < table.numberOfRows {
            (table.rowView(atRow: row, makeIfNecessary: false) as? NativeSidebarRowView)?.isHovered = on
        }
    }

    private func showHoverCard(_ id: ThreadId, row: Int, instant: Bool) {
        if window?.contentView?.subviews.contains(where: { $0 is ModalHost || $0 is CommandPaletteOverlay }) == true { return }
        guard !table.rowActionsVisible, let rowView = table.rowView(atRow: row, makeIfNecessary: false),
              let model = hoverCard?(id), let host = rowView.popupHost else { return }
        closeHoverCard()
        let popup = host.open(SidebarThreadHoverCardView(model), trigger: rowView, placement: PopupPlacement(side: .right, align: .start, sideOffset: 4),
                              motion: instant ? .none : .tooltip, pressesTrigger: false, returnsFocus: false, passive: true)
        hoverPopup = (id, popup)
    }

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

    func hoverEnded() {
        setHoverFill(from: hoverRow, to: -1)
        hoverRow = -1
        closeHoverCard()
    }

    // MARK: Drags: thread context out, pinned and inbox order within, files onto a row

    private var draggedId: ThreadId?

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard case .row(let r)? = item(atRow: row) else { return nil }
        let selected = table.selectedRowIndexes
        var ids = [r.id]
        if selected.contains(row), selected.count > 1 {
            // One pasteboard item carries the whole selection, as the composer reads the first item.
            guard row == selected.first else { return nil }
            ids = selected.compactMap { if case .row(let s)? = item(atRow: $0) { s.id } else { nil } }
        }
        let item = NSPasteboardItem()
        item.setString(ids.map(\.rawValue).joined(separator: "\n"), forType: .sidebarThreads)
        return item
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        closeHoverCard()
        draggedId = nil
        if rowIndexes.count == 1, case .row(let r)? = item(atRow: rowIndexes.first!), canSortThread(r.id) { draggedId = r.id }
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        draggedId = nil
    }

    private var sortRows: [(id: ThreadId, section: SidebarSection)?] {
        items.map { if case .row(let r) = $0 { (r.id, r.section) } else { nil } }
    }

    private func section(of id: ThreadId) -> SidebarSection? {
        rowIndex(id).flatMap { if case .row(let r)? = item(atRow: $0) { r.section } else { nil } }
    }

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        if info.draggingSource as? NSTableView === table {
            guard dropOperation == .above, let id = draggedId, let from = section(of: id),
                  let target = NativeSidebarRules.dropTarget(sortRows, moving: id, at: row), canSortDrop(id, from, target) else { return [] }
            return .move
        }
        guard info.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else { return [] }
        let target = dropOperation == .on ? row : min(row, items.count - 1)
        guard case .row? = item(atRow: target) else { return [] }
        tableView.setDropRow(target, dropOperation: .on)
        return .copy
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        if info.draggingSource as? NSTableView === table {
            guard let id = draggedId, let from = section(of: id), let target = NativeSidebarRules.dropTarget(sortRows, moving: id, at: row) else { return false }
            onSortDrop(id, from, target)
            return true
        }
        guard case .row(let r)? = item(atRow: row),
              let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }
        actions.dropFiles(r.id, urls)
        return true
    }
}

/// The table: hover tracking for the hover cards and the thread menu on right click.
final class NativeSidebarTableView: NSTableView {
    weak var list: NativeSidebarListView?
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        list?.hover(row: row(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        list?.hoverEnded()
    }

    override func mouseDown(with event: NSEvent) {
        list?.closeHoverCard()
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return nil }
        list?.hoverEnded()
        return list?.menu(for: event, row: row)
    }

    /// Return and Space open the selected row, as clicking does.
    override func keyDown(with event: NSEvent) {
        if [36, 76, 49].contains(event.keyCode), selectedRowIndexes.count == 1, let list, let item = list.item(atRow: selectedRow) {
            list.open(item)
            return
        }
        super.keyDown(with: event)
    }
}
