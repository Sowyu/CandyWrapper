import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// Glass Native's thread list (docs/glass-native.md phase 2): a view-based source list `NSTableView` with T3
/// Mobile's card and slim rows. It takes the same items and `SidebarListCache` patches as `SidebarListView`, keeps
/// them in builder order, and draws them in T3 Mobile's order (`NativeSidebarRules.displayOrder`). A change to one
/// thread reconfigures that row's cell in place, and only labels whose text changed are set.
final class NativeSidebarListView: NSScrollView, SidebarItemsPresenting, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    let table = NativeSidebarTableView()
    private(set) var items: [SidebarItem] = []
    /// Display row to index in `items`, and back.
    private(set) var order: [Int] = []
    private var rowOfItem: [Int] = []
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
    /// The environment's label for line 3, nil when unknown.
    var environmentLabel: (String) -> String? = { _ in nil }
    var environmentMachine: (String) -> String = { _ in "server" }
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
        hasVerticalScroller = true
        autohidesScrollers = true
        borderType = .noBorder
        let column = NSTableColumn(identifier: .init("thread"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .sourceList
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

    // MARK: Data

    func item(atRow row: Int) -> SidebarItem? { order.indices.contains(row) ? items[order[row]] : nil }

    /// Replaces the items. Same rows in the same order reconfigure in place; otherwise rows that came or went fade,
    /// or the table reloads when too much moved.
    func setItems(_ new: [SidebarItem], animated: Bool, generation: Int?) {
        itemsGeneration = generation
        let oldItems = items, oldOrder = order
        let newOrder = NativeSidebarRules.displayOrder(new)
        let oldKeys = oldOrder.map { oldItems[$0].key }, newKeys = newOrder.map { new[$0].key }
        items = new
        order = newOrder
        rowOfItem = Array(repeating: -1, count: new.count)
        for (row, i) in newOrder.enumerated() { rowOfItem[i] = row }
        if oldKeys == newKeys {
            for row in newOrder.indices where oldItems[oldOrder[row]] != new[newOrder[row]] {
                refresh(row: row, old: oldItems[oldOrder[row]])
            }
        } else {
            let diff = newKeys.difference(from: oldKeys)
            if animated, window != nil, !oldKeys.isEmpty, diff.count <= 60 {
                var removed = IndexSet(), inserted = IndexSet()
                for change in diff {
                    switch change {
                    case .remove(let offset, _, _): removed.insert(offset)
                    case .insert(let offset, _, _): inserted.insert(offset)
                    }
                }
                let oldByKey = Dictionary(oldOrder.map { (oldItems[$0].key, oldItems[$0]) }, uniquingKeysWith: { a, _ in a })
                table.beginUpdates()
                table.removeRows(at: removed, withAnimation: .effectFade)
                table.insertRows(at: inserted, withAnimation: .effectFade)
                table.endUpdates()
                for row in newOrder.indices where !inserted.contains(row) {
                    let item = new[newOrder[row]]
                    if let old = oldByKey[item.key], old != item { refresh(row: row, old: old) }
                }
            } else {
                closeHoverCard()
                table.reloadData()
            }
        }
        syncSelection()
    }

    /// Single rows that kept their place, from `SidebarListCache.patch` (indices into `items`).
    func patchItems(_ patch: [(index: Int, item: SidebarItem)]) -> Bool {
        for (i, item) in patch { guard i < items.count, item.key == items[i].key else { return false } }
        for (i, item) in patch where items[i] != item {
            let old = items[i]
            items[i] = item
            if rowOfItem[i] >= 0 { refresh(row: rowOfItem[i], old: old) }
        }
        syncSelection()
        return true
    }

    /// One row's item changed: its cell reconfigures if it shows, and its height is noted if it moved.
    private func refresh(row: Int, old: SidebarItem) {
        guard let item = item(atRow: row) else { return }
        if height(old) != height(item) { table.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row)) }
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
        for (row, i) in order.enumerated() {
            switch items[i] {
            case .row(let r) where r.isActive || r.isSelected: rows.insert(row)
            case .draft(let d) where d.isActive: rows.insert(row)
            case .searchResult(let r) where r.isHighlighted: rows.insert(row)
            default: break
            }
        }
        guard table.selectedRowIndexes != rows else { return }
        syncingSelection = true
        table.selectRowIndexes(rows, byExtendingSelection: false)
        syncingSelection = false
    }

    var visibleRowModels: [SidebarRowModel] {
        let range = table.rows(in: table.visibleRect)
        guard range.length > 0 else { return [] }
        return (range.location..<range.location + range.length).compactMap { if case .row(let r)? = item(atRow: $0) { r } else { nil } }
    }

    func scrollItemToVisible(_ key: String) {
        guard let i = items.firstIndex(where: { $0.key == key }), rowOfItem[i] >= 0 else { return }
        table.scrollRowToVisible(rowOfItem[i])
    }

    func rowIndex(_ id: ThreadId) -> Int? {
        let key = "thread:\(id.rawValue)"
        guard let i = items.firstIndex(where: { $0.key == key }), rowOfItem[i] >= 0 else { return nil }
        return rowOfItem[i]
    }

    // MARK: Line 3 and title measuring

    /// "branch · environment" with the machine glyph (thread-list-v2-items.tsx line 3).
    func detailLine(_ r: SidebarRowModel) -> NSAttributedString {
        typealias M = NativeSidebarMetrics
        let s = NSMutableAttributedString()
        if let branch = r.branch, !branch.isEmpty {
            s.append(NSAttributedString(string: branch, attributes: [.font: M.monoFont, .foregroundColor: NSColor.secondaryLabelColor]))
        }
        let env = r.id.environmentId
        if let env, let label = r.scratchMachineLabel ?? environmentLabel(env) {
            if s.length > 0 { s.append(NSAttributedString(string: " · ", attributes: [.font: M.detailFont, .foregroundColor: NSColor.tertiaryLabelColor])) }
            s.append(M.symbolText(NativeSidebarRules.machineSymbol(r.scratchMachine ?? environmentMachine(env)), label,
                                  font: M.detailFont, color: .secondaryLabelColor))
        }
        return s
    }

    private func hasDetailLine(_ r: SidebarRowModel) -> Bool {
        (r.branch?.isEmpty == false) || r.pullRequestBadge != nil || r.scratchMachineLabel != nil
            || r.id.environmentId.flatMap(environmentLabel) != nil
    }

    private var measuredWidth: CGFloat = 0
    private var twoLineTitles: [String: Bool] = [:]

    /// Whether a card's title wraps to a second line at the current width. Cached per title until the width changes.
    func titleNeedsTwoLines(_ title: String) -> Bool {
        let width = max(40, table.bounds.width - 2 * NativeSidebarMetrics.pad - 20)
        if width != measuredWidth { measuredWidth = width; twoLineTitles = [:] }
        if let known = twoLineTitles[title] { return known }
        let height = (title as NSString).boundingRect(with: NSSize(width: width, height: 1_000), options: [.usesLineFragmentOrigin],
                                                      attributes: [.font: NativeSidebarMetrics.titleFont]).height
        let two = height > NativeSidebarMetrics.titleFont.pointSize * 1.8
        twoLineTitles[title] = two
        return two
    }

    func height(_ item: SidebarItem) -> CGFloat {
        guard case .row(let r) = item, r.variant == .card else { return NativeSidebarMetrics.height(item, twoLines: false, line3: false) }
        return NativeSidebarMetrics.cardHeight(twoLines: titleNeedsTwoLines(r.title), line3: hasDetailLine(r))
    }

    /// The width changed: card titles wrap again.
    func widthChanged() {
        let cards = IndexSet(order.indices.filter { if case .row(let r) = items[order[$0]], r.variant == .card { true } else { false } })
        guard !cards.isEmpty else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            table.noteHeightOfRows(withIndexesChanged: cards)
        }
        for row in cards { if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? NativeSidebarCell, let item = item(atRow: row) { configure(cell, item) } }
    }

    // MARK: NSTableViewDataSource and delegate

    func numberOfRows(in tableView: NSTableView) -> Int { order.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { item(atRow: row).map(height) ?? 1 }

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
        field.font = NativeSidebarMetrics.titleFont
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
        order.map { if case .row(let r) = items[$0] { (r.id, r.section) } else { nil } }
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
        let target = dropOperation == .on ? row : min(row, order.count - 1)
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

/// The table: hover tracking for the cards, the thread menu on right click and a width change hook.
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
        list?.hoverEnded()
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return nil }
        list?.hoverEnded()
        return list?.menu(for: event, row: row)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize.width != frame.width
        super.setFrameSize(newSize)
        if changed { list?.widthChanged() }
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
