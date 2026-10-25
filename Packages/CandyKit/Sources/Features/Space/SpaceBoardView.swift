import AppKit
import DesignSystem
import SpaceFields
import SpaceModel

/// Board view of a page's items (docs/space.md section 4, "Board"), in mockup look B: faint lanes with a colored
/// dot in each header, and borderless cards with their fields as one muted line. The page header sits on top,
/// then the quiet Filter, Sort and Fields row, then the lanes, which scroll sideways and down together.
/// Every edit goes through the store's `edit`, so it saves encrypted and undoes with ⌘Z.
final class SpaceBoardView: DSView, NSMenuItemValidation {
    let store: SpaceDocumentStore
    let page: PageID
    private weak var host: SpacePageView?
    let canvas = SpaceBoardCanvas()
    private let scroll = NSScrollView()
    private let filter = ButtonView("Filter", icon: .listFilter, variant: .ghostMuted, size: .xs)
    private let sort = ButtonView("Sort", icon: .arrowUpDown, variant: .ghostMuted, size: .xs)
    private let fieldsButton = ButtonView("Fields", icon: .slidersHorizontal, variant: .ghostMuted, size: .xs)
    let undo = UndoManager()
    private var token: Int?
    static let toolbarY: CGFloat = 152
    static let lanesY: CGFloat = 186

    init(store: SpaceDocumentStore, page: PageID, host: SpacePageView?) {
        self.store = store
        self.page = page
        self.host = host
        super.init(frame: .zero)
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = canvas
        addSubview(scroll)
        for b in [filter, sort, fieldsButton] { addSubview(b) }
        filter.action = { [weak self] in self?.showFilterMenu() }
        sort.action = { [weak self] in self?.showSortMenu() }
        fieldsButton.action = { [weak self] in self?.showFieldsMenu() }
        canvas.board = self
        undo.groupsByEvent = false
        setAccessibilityRole(.group)
        setAccessibilityLabel("Board")
        // Opening Board on a page that can't group yet adds the settings, and a Status field when there's no select.
        if let record = store.pages[page], let change = SpaceBoard.setup(page, record) { store.edit([change]) }
        token = store.observe { [weak self] in self?.reload() }
        reload()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    isolated deinit { if let token { store.removeObserver(token) } }

    static func make(_ store: SpaceDocumentStore, _ page: PageID, _ host: SpacePageView) -> NSView {
        SpaceBoardView(store: store, page: page, host: host)
    }

    var record: PageRecord? { store.pages[page] }

    func items() -> [(PageID, PageRecord)] {
        store.content(of: page).compactMap { if case .page(let id, let r) = $0 { (id, r) } else { nil } }
    }

    func reload() {
        guard let record else { return }
        let items = items()
        let byID = Dictionary(items, uniquingKeysWith: { a, _ in a })
        let context = FieldContext(now: Date(), timeZone: .current)
        let columns = SpaceBoard.columns(record, items: items, context: context)
        var cards: [PageID: SpaceBoardCard] = [:]
        for column in columns { for id in column.cards where cards[id] == nil { cards[id] = byID[id].map { SpaceBoard.card($0, schema: record) } } }
        canvas.update(columns: columns, cards: cards, sorted: !(record.views.board?.sort.isEmpty ?? true),
                      canAddOption: SpaceBoard.groupField(record).map { $0.field.type != .checkbox } ?? false)
        sort.variant = record.views.board?.sort.isEmpty ?? true ? .ghostMuted : .ghost
        filter.variant = record.views.board?.filter.isEmpty ?? true ? .ghostMuted : .ghost
    }

    func open(_ id: PageID) { host?.onOpenPage(id) }

    // MARK: Edits

    /// One undoable edit.
    @discardableResult
    func commit(_ changes: [RecordChange], name: String) -> Bool {
        guard let entry = store.edit(changes) else { return false }
        undo.beginUndoGrouping()
        register(UndoBox(entry), name: name)
        undo.endUndoGrouping()
        return true
    }

    private func register(_ box: UndoBox, name: String? = nil) {
        undo.registerUndo(withTarget: self) { $0.perform(box) }
        if let name { undo.setActionName(name) }
    }

    private func perform(_ box: UndoBox) {
        canvas.endEditing(commit: false)
        if let redo = store.undo(box.entry), !redo.isEmpty { register(UndoBox(redo)) }
    }

    override var acceptsFirstResponder: Bool { true }
    @objc func undo(_ sender: Any?) { canvas.endEditing(commit: true); if undo.canUndo { undo.undo() } }
    @objc func redo(_ sender: Any?) { if undo.canRedo { undo.redo() } }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(undo(_:)) { return undo.canUndo }
        if item.action == #selector(redo(_:)) { return undo.canRedo }
        return true
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self || window?.firstResponder === canvas else { return super.performKeyEquivalent(with: event) }
        switch (event.modifierFlags.intersection([.command, .shift, .option, .control]), event.charactersIgnoringModifiers?.lowercased()) {
        case ([.command], "z"): undo(nil); return true
        case ([.command, .shift], "z"): redo(nil); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }

    func move(_ card: PageID, from: FieldGroupKey, to column: SpaceBoardColumn, before: PageID?) {
        guard let record, let change = SpaceBoard.move(card, from: from, to: column, before: before, page: page, record: record, content: store.content(of: page)) else { return }
        commit([change], name: "Move card")
    }

    func newCard(in column: SpaceBoardColumn) {
        guard let record else { return }
        let id = PageID()
        guard let change = SpaceBoard.newCard(id, in: column, page: page, record: record, content: store.content(of: page), now: SpaceClock.now()),
              commit([change], name: "New card") else { return }
        canvas.beginEditing(.card(id))
    }

    func rename(_ id: PageID, _ title: String) {
        guard let r = store.pages[id], r.title != title else { return }
        commit([RecordChange(kind: .page, id: id, set: ["title": .string(title)])], name: "Rename")
    }

    func toggleDone(_ id: PageID) {
        guard let r = store.pages[id], case .checkbox(let on)? = r.props[FieldID.done] else { return }
        commit([RecordChange(kind: .page, id: id, set: ["props." + FieldID.done: .bool(!on)])], name: on ? "Uncheck" : "Check")
    }

    func addOption() {
        guard let record else { return }
        let id = UUID().uuidString.lowercased()
        let count = (SpaceBoard.groupField(record)?.field.options?.count ?? 0) + 1
        guard let change = SpaceBoard.addOption(id, name: "Option \(count)", page: page, record: record), commit([change], name: "Add column") else { return }
        canvas.beginEditing(.option(id))
        DispatchQueue.main.async { [weak self] in self?.canvas.scrollToEnd() }
    }

    func renameOption(_ id: String, _ name: String) {
        guard let record, SpaceBoard.groupField(record)?.field.options?[id]?.name != name else { return }
        if let change = SpaceBoard.editOptions(page, record, { $0[id]?.name = name }) { commit([change], name: "Rename column") }
    }

    // MARK: Menus

    func showColumnMenu(_ column: SpaceBoardColumn, at point: NSPoint) {
        guard case .option(let id) = column.key, let record else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(SpaceMenuItem("Rename") { [weak self] in self?.canvas.beginEditing(.option(id)) })
        let colors = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for color in FieldColor.allCases {
            let item = SpaceMenuItem(color.rawValue.capitalized) { [weak self] in
                guard let self, let record = self.record, let change = SpaceBoard.editOptions(page, record, { $0[id]?.color = color }) else { return }
                commit([change], name: "Column color")
            }
            item.state = column.color == color ? .on : .off
            item.image = SpaceBoardCanvas.dotImage(color)
            sub.addItem(item)
        }
        colors.submenu = sub
        menu.addItem(colors)
        menu.addItem(SpaceMenuItem("Hide") { [weak self] in
            guard let self, let record = self.record, let change = SpaceBoard.editSettings(page, record, { $0.hidden.append(id) }) else { return }
            commit([change], name: "Hide column")
        })
        menu.addItem(.separator())
        let delete = SpaceMenuItem("Delete") { [weak self] in
            guard let self, let record = self.record else { return }
            commit(SpaceBoard.deleteOption(id, page: page, record: record, items: items()), name: "Delete column")
        }
        delete.isEnabled = (SpaceBoard.groupField(record)?.field.options?.count ?? 0) > 1
        menu.addItem(delete)
        menu.popUp(positioning: nil, at: point, in: canvas)
    }

    private func showFilterMenu() {
        guard let record, let settings = record.views.board else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        if settings.filter.isEmpty {
            let none = NSMenuItem(title: "No filters", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        } else {
            menu.addItem(SpaceMenuItem(settings.filter.count == 1 ? "Clear the filter" : "Clear \(settings.filter.count) filters") { [weak self] in
                guard let self, let record = self.record, let change = SpaceBoard.editSettings(page, record, { $0.filter = [] }) else { return }
                commit([change], name: "Clear filters")
            })
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: filter.bounds.maxY + 4), in: filter)
    }

    /// One sort at a time from here: Manual, or a field. Picking the current field again flips its direction.
    private func showSortMenu() {
        guard let record, let settings = record.views.board else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let manual = SpaceMenuItem("Manual") { [weak self] in self?.setSort([]) }
        manual.state = settings.sort.isEmpty ? .on : .off
        menu.addItem(manual)
        menu.addItem(.separator())
        let current = settings.sort.first
        for (id, name) in [(FieldID.title, record.titleName ?? SpaceTableModel.defaultTitleName)] + sortedFields(record).map({ ($0.key, $0.value.name) }) {
            let on = current?.field == id
            let item = SpaceMenuItem(on ? "\(name) \(current!.desc ? "↓" : "↑")" : name) { [weak self] in
                self?.setSort([Sort(field: id, desc: on ? !current!.desc : false)])
            }
            item.state = on ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sort.bounds.maxY + 4), in: sort)
    }

    private func setSort(_ sorts: [Sort]) {
        guard let record, let change = SpaceBoard.editSettings(page, record, { $0.sort = sorts }) else { return }
        commit([change], name: "Sort")
    }

    private func showFieldsMenu() {
        guard let record, let settings = record.views.board else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let group = NSMenuItem(title: "Group by", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (id, field) in sortedFields(record) where SpaceBoard.groupTypes.contains(field.type) {
            let item = SpaceMenuItem(field.name) { [weak self] in
                guard let self, let record = self.record, let change = SpaceBoard.editSettings(page, record, { $0.group = id; $0.show.removeAll { $0 == id } }) else { return }
                commit([change], name: "Group by")
            }
            item.state = settings.group == id ? .on : .off
            sub.addItem(item)
        }
        group.submenu = sub
        menu.addItem(group)
        menu.addItem(.separator())
        let header = NSMenuItem(title: "On cards", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for (id, field) in sortedFields(record) where id != settings.group && id != FieldID.due {
            let shown = settings.show.contains(id)
            let item = SpaceMenuItem(field.name) { [weak self] in
                guard let self, let record = self.record, let change = SpaceBoard.editSettings(page, record, { s in
                    if shown { s.show.removeAll { $0 == id } } else { s.show.append(id) }
                }) else { return }
                commit([change], name: shown ? "Hide field" : "Show field")
            }
            item.state = shown ? .on : .off
            item.isEnabled = shown || settings.show.count < 3
            menu.addItem(item)
        }
        let options = SpaceBoard.groupField(record)?.field.options ?? [:]
        let hidden = settings.hidden.filter { options[$0] != nil }
        if !hidden.isEmpty {
            menu.addItem(.separator())
            let title = NSMenuItem(title: "Hidden columns", action: nil, keyEquivalent: "")
            title.isEnabled = false
            menu.addItem(title)
            for id in hidden {
                let item = SpaceMenuItem(options[id]!.name.isEmpty ? "Untitled" : options[id]!.name) { [weak self] in
                    guard let self, let record = self.record, let change = SpaceBoard.editSettings(page, record, { $0.hidden.removeAll { $0 == id } }) else { return }
                    commit([change], name: "Show column")
                }
                item.image = SpaceBoardCanvas.dotImage(options[id]!.color)
                menu.addItem(item)
            }
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: fieldsButton.bounds.maxY + 4), in: fieldsButton)
    }

    private func sortedFields(_ record: PageRecord) -> [(key: String, value: FieldDefinition)] {
        record.fields.sorted { ($0.value.order, $0.key) < ($1.value.order, $1.key) }
    }

    // MARK: Layout

    /// The page header comes in from `SpacePageView.mount` after init; the toolbar stays above it so it gets clicks.
    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        if subview is SpacePageHeaderView { for b in [filter, sort, fieldsButton] { addSubview(b, positioned: .above, relativeTo: subview) } }
    }

    override func layout() {
        super.layout()
        scroll.frame = NSRect(x: 0, y: Self.lanesY, width: bounds.width, height: max(0, bounds.height - Self.lanesY))
        var x = SpaceBoardCanvas.inset - 8
        for b in [filter, sort, fieldsButton] {
            let s = b.intrinsicContentSize
            b.frame = NSRect(x: x, y: Self.toolbarY, width: s.width, height: 24)
            x += s.width + 4
        }
        canvas.sizeToFit(minHeight: scroll.contentSize.height)
    }
}

/// The lanes and cards, drawn in one view so 500 cards cost no views. It tracks hover, clicks and drags itself.
final class SpaceBoardCanvas: DSView, NSTextFieldDelegate {
    weak var board: SpaceBoardView?
    static let inset: CGFloat = 32
    static let laneWidth: CGFloat = 260
    static let gap: CGFloat = 16
    static let pad: CGFloat = 8
    static let headerHeight: CGFloat = 28
    static let cardGap: CGFloat = 6
    static let newHeight: CGFloat = 30
    static let titleFont = DSFont.ui(13, weight: .medium)
    static let metaFont = DSFont.ui(12)

    enum Target: Equatable { case card(Int, PageID), new(Int), menu(Int), add, check(PageID) }
    enum Editing: Equatable { case card(PageID), option(String) }

    struct Lane {
        var column: SpaceBoardColumn
        var rect: CGRect
        var cards: [(id: PageID, rect: CGRect)]
        var new: CGRect
        var menu: CGRect?
    }

    private(set) var lanes: [Lane] = []
    private var cards: [PageID: SpaceBoardCard] = [:]
    private var titleHeights: [PageID: CGFloat] = [:]
    private var sorted = false
    private var addRect: CGRect?
    private var hovered: Target? { didSet { if hovered != oldValue { needsDisplay = true } } }
    private var press: (point: NSPoint, target: Target)?
    private(set) var drag: (id: PageID, from: Int, point: NSPoint, offset: CGSize, drop: (lane: Int, before: PageID?)?)?
    private var editing: (target: Editing, field: NSTextField)?
    private var pendingEdit: Editing?

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        setAccessibilityRole(.group)
        setAccessibilityLabel("Board columns")
        mediaToken = NotificationCenter.default.addObserver(forName: SpaceMedia.didLoad, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.needsDisplay = true }
        }
    }

    private var mediaToken: NSObjectProtocol?
    isolated deinit { if let mediaToken { NotificationCenter.default.removeObserver(mediaToken) } }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var wantsUpdateLayer: Bool { false }

    /// A title still being typed when the user switches view or page is kept.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { endEditing(commit: true) }
        super.viewWillMove(toWindow: newWindow)
    }

    func update(columns: [SpaceBoardColumn], cards: [PageID: SpaceBoardCard], sorted: Bool, canAddOption: Bool) {
        let width = Self.laneWidth - 2 * Self.pad - 20
        var heights: [PageID: CGFloat] = [:]
        for (id, card) in cards {
            let w = (card.todo ? width - 24 : width) - (card.icon == .none ? 0 : 22)
            if let old = self.cards[id], old.title == card.title, old.todo == card.todo, (old.icon == .none) == (card.icon == .none), let h = titleHeights[id] { heights[id] = h; continue }
            let text = card.title.isEmpty ? "Untitled" : card.title
            heights[id] = ceil(NSAttributedString(string: text, attributes: [.font: Self.titleFont]).boundingRect(
                with: NSSize(width: w, height: 1000), options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
        }
        self.cards = cards
        titleHeights = heights
        self.sorted = sorted
        var x = Self.inset
        lanes = columns.enumerated().map { i, column in
            var y = Self.pad + Self.headerHeight + Self.cardGap
            var rects: [(PageID, CGRect)] = []
            for id in column.cards {
                let h = cardHeight(id)
                rects.append((id, CGRect(x: x + Self.pad, y: y, width: Self.laneWidth - 2 * Self.pad, height: h)))
                y += h + Self.cardGap
            }
            let new = CGRect(x: x + Self.pad, y: y, width: Self.laneWidth - 2 * Self.pad, height: Self.newHeight)
            let rect = CGRect(x: x, y: 0, width: Self.laneWidth, height: new.maxY + Self.pad)
            let menu: CGRect? = if case .option = column.key { CGRect(x: rect.maxX - Self.pad - 24, y: Self.pad + 2, width: 24, height: 24) } else { nil }
            x += Self.laneWidth + Self.gap
            _ = i
            return Lane(column: column, rect: rect, cards: rects, new: new, menu: menu)
        }
        addRect = canAddOption ? CGRect(x: x, y: 0, width: 36, height: 32) : nil
        sizeToFit(minHeight: enclosingScrollView?.contentSize.height ?? 0)
        needsDisplay = true
        if let pendingEdit { self.pendingEdit = nil; beginEditing(pendingEdit) }
        else if let editing { place(editing.field, for: editing.target) }
    }

    private func cardHeight(_ id: PageID) -> CGFloat {
        guard let card = cards[id] else { return 38 }
        var h = 9 + (titleHeights[id] ?? 17) + 9
        if !card.meta.isEmpty { h += 20 }
        if card.due != nil { h += 20 }
        return max(h, 36)
    }

    func sizeToFit(minHeight: CGFloat) {
        let width = (addRect?.maxX ?? (lanes.last?.rect.maxX ?? 0)) + Self.inset
        let height = max(minHeight, (lanes.map(\.rect.maxY).max() ?? 0) + 24)
        let size = NSSize(width: max(width, enclosingScrollView?.contentSize.width ?? 0), height: height)
        if frame.size != size { setFrameSize(size) }
    }

    func scrollToEnd() { scrollToVisible(CGRect(x: bounds.maxX - 1, y: 0, width: 1, height: 1)) }

    // MARK: Drawing

    static func dotColor(_ color: FieldColor) -> NSColor {
        let (dark, light): (UInt32, UInt32) = switch color {
        case .brown: (0xC39A7A, 0x9A6B4A)
        case .orange: (0xE8A060, 0xD9782D)
        case .yellow: (0xE0C060, 0xC29A1E)
        case .green: (0x6CC08A, 0x3F9D5E)
        case .blue: (0x74AEEA, 0x3B82D6)
        case .purple: (0xB494E6, 0x8B5CD6)
        case .pink: (0xE68FBF, 0xD0569B)
        case .red: (0xF08A84, 0xD64545)
        default: (0xA3A3A4, 0x8E8E93)
        }
        func c(_ v: UInt32) -> NSColor { NSColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1) }
        return NSColor(name: nil) { $0.isDark ? c(dark) : c(light) }
    }

    static func dotImage(_ color: FieldColor) -> NSImage {
        NSImage(size: NSSize(width: 10, height: 10), flipped: false) { r in
            dotColor(color).setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }

    private static let laneFill = Themed.color(\.foreground, 0.025)
    private static let cardFill = Themed.color(light: \.background, 1, dark: \.foreground, 0.055)
    private static let cardHover = Themed.color(light: \.background, 1, dark: \.foreground, 0.085)
    private static let cardEdge = Themed.color(light: \.foreground, 0.07, dark: \.foreground, 0)
    private static let hoverFill = Themed.color(\.foreground, 0.06)

    override func draw(_ dirtyRect: NSRect) {
        for (i, lane) in lanes.enumerated() where lane.rect.intersects(dirtyRect) {
            let target = drag?.drop?.lane == i
            (target ? Themed.color(\.foreground, 0.045) : Self.laneFill).setFill()
            NSBezierPath(roundedRect: lane.rect, xRadius: 12, yRadius: 12).fill()
            drawHeader(lane, i)
            for card in lane.cards where card.rect.intersects(dirtyRect) {
                let dragged = drag?.id == card.id && drag?.from == i
                drawCard(card.id, in: card.rect, hover: hovered == .card(i, card.id) || hovered == .check(card.id), alpha: dragged ? 0.35 : 1)
            }
            let newHover = hovered == .new(i)
            if newHover {
                Self.hoverFill.setFill()
                NSBezierPath(roundedRect: lane.new, xRadius: 8, yRadius: 8).fill()
            }
            let newColor = newHover ? Themed.color(\.mutedForeground) : Themed.color(\.placeholder)
            drawPlus(CGRect(x: lane.new.minX + 10, y: lane.new.midY - 6, width: 12, height: 12), newColor)
            NSAttributedString(string: "New", attributes: [.font: DSFont.ui(13), .foregroundColor: newColor])
                .draw(at: CGPoint(x: lane.new.minX + 30, y: lane.new.midY - 8.5))
        }
        if let addRect {
            if hovered == .add {
                Self.hoverFill.setFill()
                NSBezierPath(roundedRect: addRect, xRadius: 8, yRadius: 8).fill()
            }
            drawPlus(CGRect(x: addRect.midX - 7, y: addRect.midY - 7, width: 14, height: 14), Themed.color(hovered == .add ? \.foreground : \.iconMuted))
        }
        if let drag, let drop = drag.drop, !sorted || drop.lane != drag.from {
            SpacePageMetrics.accent.setFill()
            CGRect(x: lanes[drop.lane].rect.minX + Self.pad, y: dropY(drop) - 1, width: Self.laneWidth - 2 * Self.pad, height: 2).fill()
        }
        if let drag {
            let w = Self.laneWidth - 2 * Self.pad
            let r = CGRect(x: drag.point.x - drag.offset.width, y: drag.point.y - drag.offset.height, width: w, height: cardHeight(drag.id))
            Themed.color(\.background).setFill()
            NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8).fill()
            drawCard(drag.id, in: r, hover: true, alpha: 1)
            Themed.color(\.foreground, 0.12).setStroke()
            let edge = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
            edge.lineWidth = 1
            edge.stroke()
        }
    }

    private func drawHeader(_ lane: Lane, _ i: Int) {
        let r = lane.rect
        let mid = Self.pad + Self.headerHeight / 2
        Self.dotColor(lane.column.color).setFill()
        NSBezierPath(ovalIn: CGRect(x: r.minX + Self.pad + 6, y: mid - 4, width: 8, height: 8)).fill()
        if editing?.target != .option(optionID(lane.column) ?? "") || optionID(lane.column) == nil {
            let title = NSAttributedString(string: lane.column.title.isEmpty ? "Untitled" : lane.column.title,
                                           attributes: [.font: DSFont.ui(13, weight: .medium), .foregroundColor: Themed.color(\.foreground)])
            let maxW = r.width - 2 * Self.pad - 22 - 60
            let w = min(maxW, ceil(title.size().width))
            title.draw(with: CGRect(x: r.minX + Self.pad + 22, y: mid - 9, width: w, height: 18), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            NSAttributedString(string: "\(lane.column.cards.count)", attributes: [.font: DSFont.ui(12), .foregroundColor: Themed.color(\.secondaryLabel)])
                .draw(at: CGPoint(x: r.minX + Self.pad + 22 + w + 8, y: mid - 8))
        }
        if let menu = lane.menu {
            if hovered == .menu(i) {
                Self.hoverFill.setFill()
                NSBezierPath(roundedRect: menu, xRadius: 6, yRadius: 6).fill()
            }
            Themed.color(hovered == .menu(i) ? \.foreground : \.iconMuted).setFill()
            for dx in [-4.0, 0, 4] { NSBezierPath(ovalIn: CGRect(x: menu.midX + dx - 1, y: menu.midY - 1, width: 2, height: 2)).fill() }
        }
    }

    private func drawCard(_ id: PageID, in r: CGRect, hover: Bool, alpha: CGFloat) {
        guard let card = cards[id], let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.setAlpha(alpha)
        (hover ? Self.cardHover : Self.cardFill).setFill()
        NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8).fill()
        Self.cardEdge.setStroke()
        NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8).stroke()
        var x = r.minX + 10
        if card.todo {
            SpaceBlockFragment.drawCheckbox(CGRect(x: x, y: r.minY + 10.5, width: 16, height: 16), on: card.done)
            x += 24
        }
        if SpacePageIcon.draw(card.icon, in: CGRect(x: x, y: r.minY + 10.5, width: 16, height: 16)) { x += 22 }
        let editingThis = editing?.target == .card(id)
        if !editingThis {
            let empty = card.title.isEmpty
            let color = empty ? Themed.color(\.placeholder) : card.done ? Themed.color(\.mutedForeground) : Themed.color(\.foreground)
            NSAttributedString(string: empty ? "Untitled" : card.title, attributes: [.font: Self.titleFont, .foregroundColor: color])
                .draw(with: CGRect(x: x, y: r.minY + 9, width: r.maxX - 10 - x, height: titleHeights[id] ?? 17), options: [.usesLineFragmentOrigin, .usesFontLeading])
        }
        var y = r.minY + 9 + (titleHeights[id] ?? 17) + 3
        let lineWidth = r.maxX - 10 - (r.minX + 10)
        if !card.meta.isEmpty {
            NSAttributedString(string: card.meta, attributes: [.font: Self.metaFont, .foregroundColor: Themed.color(\.secondaryLabel), .paragraphStyle: Self.truncating])
                .draw(with: CGRect(x: r.minX + 10, y: y, width: lineWidth, height: 17), options: [.usesLineFragmentOrigin])
            y += 20
        }
        if let due = card.due {
            NSAttributedString(string: due.text, attributes: [.font: Self.metaFont, .foregroundColor: due.late ? SpacePageEditor.lateColor : Themed.color(\.secondaryLabel), .paragraphStyle: Self.truncating])
                .draw(with: CGRect(x: r.minX + 10, y: y, width: lineWidth, height: 17), options: [.usesLineFragmentOrigin])
        }
        context.restoreGState()
    }

    private static let truncating: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingTail
        return p
    }()

    private func drawPlus(_ r: CGRect, _ color: NSColor) {
        color.setStroke()
        let p = NSBezierPath()
        p.move(to: CGPoint(x: r.midX, y: r.minY + 1)); p.line(to: CGPoint(x: r.midX, y: r.maxY - 1))
        p.move(to: CGPoint(x: r.minX + 1, y: r.midY)); p.line(to: CGPoint(x: r.maxX - 1, y: r.midY))
        p.lineWidth = 1.5
        p.lineCapStyle = .round
        p.stroke()
    }

    private func optionID(_ column: SpaceBoardColumn) -> String? { if case .option(let id) = column.key { id } else { nil } }

    // MARK: Hit testing

    func target(at p: NSPoint) -> Target? {
        if let addRect, addRect.contains(p) { return .add }
        for (i, lane) in lanes.enumerated() where lane.rect.contains(p) {
            if let menu = lane.menu, menu.insetBy(dx: -2, dy: -2).contains(p) { return .menu(i) }
            if lane.new.contains(p) { return .new(i) }
            for card in lane.cards where card.rect.contains(p) {
                if cards[card.id]?.todo == true, CGRect(x: card.rect.minX + 4, y: card.rect.minY + 4, width: 28, height: 28).contains(p) { return .check(card.id) }
                return .card(i, card.id)
            }
        }
        return nil
    }

    /// Where a card dragged to `p` lands: the lane under it, or the nearest one, and the card it goes before.
    func drop(at p: NSPoint, dragging id: PageID) -> (lane: Int, before: PageID?)? {
        guard !lanes.isEmpty else { return nil }
        let i = lanes.indices.min { abs(lanes[$0].rect.midX - p.x) < abs(lanes[$1].rect.midX - p.x) }!
        if sorted { return (i, nil) }
        let before = lanes[i].cards.first { $0.id != id && $0.rect.midY > p.y }?.id
        return (i, before)
    }

    private func dropY(_ drop: (lane: Int, before: PageID?)) -> CGFloat {
        let lane = lanes[drop.lane]
        if let before = drop.before, let r = lane.cards.first(where: { $0.id == before })?.rect { return r.minY - Self.cardGap / 2 }
        if let last = lane.cards.last(where: { $0.id != drag?.id }) { return last.rect.maxY + Self.cardGap / 2 }
        return Self.pad + Self.headerHeight + Self.cardGap / 2
    }

    // MARK: Mouse

    override func mouseMoved(with event: NSEvent) {
        guard drag == nil else { return }
        hovered = target(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) { if drag == nil { hovered = nil } }

    override func mouseDown(with event: NSEvent) {
        endEditing(commit: true)
        window?.makeFirstResponder(board ?? self)
        let p = convert(event.locationInWindow, from: nil)
        press = target(at: p).map { (p, $0) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let press, case .card(let lane, let id) = press.target else { return }
        let p = convert(event.locationInWindow, from: nil)
        if drag == nil {
            guard hypot(p.x - press.point.x, p.y - press.point.y) >= 4, let r = lanes[lane].cards.first(where: { $0.id == id })?.rect else { return }
            drag = (id, lane, p, CGSize(width: press.point.x - r.minX, height: press.point.y - r.minY), nil)
            hovered = nil
            NSCursor.closedHand.push()
        }
        drag?.point = p
        drag?.drop = drop(at: p, dragging: id)
        autoscroll(with: event)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { press = nil }
        if let d = drag {
            drag = nil
            NSCursor.pop()
            needsDisplay = true
            guard let drop = d.drop, let board else { return }
            let from = lanes[d.from], to = lanes[drop.lane]
            // Dropping a card back where it was writes nothing.
            if d.from == drop.lane {
                if sorted { return }
                let ids = from.cards.map(\.id)
                if let i = ids.firstIndex(of: d.id), (i + 1 < ids.count ? ids[i + 1] : nil) == drop.before { return }
            }
            board.move(d.id, from: from.column.key, to: to.column, before: drop.before)
            return
        }
        guard let press, let board, target(at: convert(event.locationInWindow, from: nil)) == press.target else { return }
        switch press.target {
        case .card(_, let id): board.open(id)
        case .check(let id): board.toggleDone(id)
        case .new(let i): board.newCard(in: lanes[i].column)
        case .menu(let i):
            if let menu = lanes[i].menu { board.showColumnMenu(lanes[i].column, at: NSPoint(x: menu.minX, y: menu.maxY + 4)) }
        case .add: board.addOption()
        }
    }

    // MARK: Inline editing

    func beginEditing(_ target: Editing) {
        endEditing(commit: true)
        guard frameFor(target) != nil else { pendingEdit = target; return }
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.delegate = self
        switch target {
        case .card(let id):
            field.font = Self.titleFont
            field.stringValue = board?.store.pages[id]?.title ?? ""
            field.placeholderString = "Untitled"
            field.setAccessibilityLabel("Card title")
        case .option(let id):
            field.font = DSFont.ui(13, weight: .medium)
            field.stringValue = lanes.first { optionID($0.column) == id }?.column.title ?? ""
            field.setAccessibilityLabel("Column name")
        }
        field.textColor = Themed.color(\.foreground)
        addSubview(field)
        editing = (target, field)
        place(field, for: target)
        needsDisplay = true
        if let r = frameFor(target) { scrollToVisible(r.insetBy(dx: -8, dy: -8)) }
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    private func frameFor(_ target: Editing) -> CGRect? {
        switch target {
        case .card(let id):
            guard let r = lanes.lazy.compactMap({ $0.cards.first { $0.id == id }?.rect }).first else { return nil }
            let x = r.minX + 10 + (cards[id]?.todo == true ? 24 : 0) + (cards[id].map { $0.icon == .none } == false ? 22 : 0) - 2
            return CGRect(x: x, y: r.minY + 8, width: r.maxX - 8 - x, height: 19)
        case .option(let id):
            guard let lane = lanes.first(where: { optionID($0.column) == id }) else { return nil }
            return CGRect(x: lane.rect.minX + Self.pad + 20, y: Self.pad + 5, width: Self.laneWidth - 2 * Self.pad - 20 - 30, height: 19)
        }
    }

    private func place(_ field: NSTextField, for target: Editing) {
        if let r = frameFor(target) { field.frame = r } else { endEditing(commit: false) }
    }

    func endEditing(commit: Bool) {
        guard let (target, field) = editing else { return }
        editing = nil
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.delegate = nil
        let hadFocus = window?.firstResponder === field.currentEditor()
        field.removeFromSuperview()
        if hadFocus { window?.makeFirstResponder(board ?? self) }
        needsDisplay = true
        guard commit else { return }
        switch target {
        case .card(let id): board?.rename(id, text)
        case .option(let id): if !text.isEmpty { board?.renameOption(id, text) }
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) { endEditing(commit: true); return true }
        if selector == #selector(NSResponder.cancelOperation(_:)) { endEditing(commit: false); return true }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if let editing, obj.object as? NSTextField === editing.field { endEditing(commit: true) }
    }
}
