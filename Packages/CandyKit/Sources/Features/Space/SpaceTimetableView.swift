import AppKit
import DesignSystem
import SpaceEngine
import SpaceFields
import SpaceModel

/// Timetable view (docs/space.md "Timetable"), mockup look A: a week grid of a page's items with times, each slot
/// washed with its item's color and a colored left edge. Dragging on empty grid creates an item, dragging a slot
/// moves it and its bottom edge resizes it, snapping to 15 minutes. Every edit goes through the store's apply path,
/// so it saves encrypted and undoes like the editor's.
final class SpaceTimetableView: DSView {
    static let margin: CGFloat = 32
    static let gutter: CGFloat = 52
    static let hour: CGFloat = 48
    static let dayHeader: CGFloat = 34
    static let lane: CGFloat = 26
    /// Overrides the device zone for on-screen checks: `-CWSpaceTimeZone Europe/London` at launch.
    static let zoneOverrideKey = "CWSpaceTimeZone"

    let store: SpaceDocumentStore
    let page: PageID
    weak var header: NSView?
    var onOpenPage: (PageID) -> Void = { _ in }
    let undo = UndoManager()
    /// The device's zone. Tests set it; the app reads the system zone, or the override above.
    var zone: TimeZone { didSet { if zone != oldValue { weekStart = SpaceTimetableLayout.weekStart(containing: now(), zone: zone); reload() } } }
    var now: () -> Date = Date.init
    private(set) var weekStart: Date
    private(set) var week = SpaceTimetableWeek()
    private(set) var items: [PageID: PageRecord] = [:]
    private(set) var dayStarts: [Date] = []

    let scroll = NSScrollView()
    let grid: SpaceTimetableGrid
    private let previous = ButtonView(nil, icon: .chevronLeft, variant: .ghost, size: .iconXs)
    private let next = ButtonView(nil, icon: .chevronRight, variant: .ghost, size: .iconXs)
    private let weekLabel = LabelView("This week", font: DSFont.ui(13, weight: .medium), color: Themed.color(\.foreground))
    private let today = ButtonView("Today", variant: .outline, size: .xs)
    private var token: Int?
    private var observers: [NSObjectProtocol] = []
    private var scrolledToStart = false
    private var drawnSize = NSSize.zero

    /// Puts a Timetable over the page view's stub, under its header. This is the one call `SpacePageView.mount` makes.
    @discardableResult
    static func install(in stub: NSView, header: NSView, store: SpaceDocumentStore, page: PageID,
                        onOpenPage: @escaping (PageID) -> Void) -> SpaceTimetableView {
        for v in stub.subviews where v !== header { v.isHidden = true }
        let view = SpaceTimetableView(store: store, page: page)
        view.header = header
        view.onOpenPage = onOpenPage
        view.frame = stub.bounds
        view.autoresizingMask = [.width, .height]
        stub.addSubview(view, positioned: .below, relativeTo: header)
        // The page view sizes its header to the 720pt text column; the Timetable uses the full width, so the
        // header follows the grid's margins. ponytail: fixed up after each page layout, move the full-width rule into
        // SpacePageView.layout once Board and Table land.
        header.postsFrameChangedNotifications = true
        view.observers.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: header, queue: .main) { [weak view] _ in
            MainActor.assumeIsolated { view?.fitHeader() }
        })
        view.fitHeader()
        return view
    }

    init(store: SpaceDocumentStore, page: PageID, zone: TimeZone? = nil) {
        self.store = store
        self.page = page
        let zone = zone ?? Self.deviceZone()
        self.zone = zone
        weekStart = SpaceTimetableLayout.weekStart(containing: Date(), zone: zone)
        grid = SpaceTimetableGrid()
        super.init(frame: .zero)
        undo.groupsByEvent = false
        grid.owner = self
        scroll.documentView = grid
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        scroll.verticalScrollElasticity = .allowed
        addSubview(scroll)
        weekLabel.lineHeight = 18
        weekLabel.alignment = .center
        previous.setAccessibilityLabel("Previous week")
        next.setAccessibilityLabel("Next week")
        previous.action = { [weak self] in self?.shiftWeek(-1) }
        next.action = { [weak self] in self?.shiftWeek(1) }
        today.action = { [weak self] in self?.goToToday() }
        [previous, weekLabel, next, today].forEach(addSubview)
        token = store.observe { [weak self] in self?.reload() }
        let center = NotificationCenter.default
        for name in [NSNotification.Name.NSSystemTimeZoneDidChange, .NSCalendarDayChanged] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    NSTimeZone.resetSystemTimeZone()
                    guard let self else { return }
                    let current = Self.deviceZone()
                    if current != self.zone { self.zone = current } else { self.reload() }
                }
            })
        }
        setAccessibilityElement(false)
        reload()
        // Opening Timetable on a page without a date field adds "When". Deferred, since mount runs inside a store callback.
        DispatchQueue.main.async { [weak self] in self?.ensureSettings() }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    isolated deinit {
        if let token { store.removeObserver(token) }
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    static func deviceZone() -> TimeZone {
        if let id = UserDefaults.standard.string(forKey: zoneOverrideKey), let zone = TimeZone(identifier: id) { return zone }
        return TimeZone.current
    }

    // MARK: Settings and data

    var settings: TimetableViewSettings {
        let record = store.pages[page]
        if let s = record?.views.timetable, record?.fields[s.field]?.type == .date { return s }
        return TimetableViewSettings(field: Self.dateField(record) ?? "when")
    }

    /// The page's first date field by order, if it has one.
    static func dateField(_ record: PageRecord?) -> String? {
        record?.fields.filter { $0.value.type == .date }.min { ($0.value.order, $0.key) < ($1.value.order, $1.key) }?.key
    }

    func ensureSettings() {
        guard let record = store.pages[page] else { return }
        if let s = record.views.timetable, record.fields[s.field]?.type == .date { return }
        var set: [String: JSONValue] = [:]
        var field = Self.dateField(record)
        if field == nil {
            var id = "when"
            var n = 2
            while record.fields[id] != nil { id = "when\(n)"; n += 1 }
            let last = record.fields.values.map(\.order).max()
            let def = FieldDefinition(name: "When", type: .date, order: (try? OrderKey.between(last, nil)) ?? (try! OrderKey.between(nil, nil)))
            set["fields." + id] = try? JSONValue(encoding: def)
            field = id
        }
        var s = record.views.timetable ?? TimetableViewSettings(field: field!)
        s.field = field!
        set["views.timetable"] = try? JSONValue(encoding: s)
        store.edit([RecordChange(kind: .page, id: page, set: set.compactMapValues { $0 })])
    }

    func reload() {
        guard let record = store.pages[page] else { return }
        let s = settings
        var children: [FieldItem] = []
        for case .page(let id, let r) in store.content(of: page) { children.append(FieldItem(id: id, page: r)) }
        // A filter the engine can't read shows every item rather than none.
        let shown = (try? FieldQuery.evaluate(children, fields: record.fields, filters: s.filter, context: FieldContext(now: now(), timeZone: zone))) ?? children
        items = Dictionary(uniqueKeysWithValues: shown.map { ($0.id, $0.page) })
        dayStarts = SpaceTimetableLayout.dayStarts(weekStart, days: s.days, zone: zone)
        week = SpaceTimetableLayout.layout(shown.map { ($0.id, $0.page) }, field: s.field, weekStart: weekStart, days: s.days, zone: zone)
        updateWeekLabel()
        needsLayout = true
        needsDisplay = true
        grid.needsDisplay = true
        grid.invalidateAccessibility()
    }

    private func updateWeekLabel() {
        let current = SpaceTimetableLayout.weekStart(containing: now(), zone: zone)
        let weeks = SpaceTimetableLayout.calendar(zone).dateComponents([.weekOfYear], from: current, to: weekStart).weekOfYear ?? 0
        switch weeks {
        case 0: weekLabel.text = "This week"
        case 1: weekLabel.text = "Next week"
        case -1: weekLabel.text = "Last week"
        default: weekLabel.text = "Week of " + Self.format("d MMM", weekStart, zone)
        }
        needsLayout = true
    }

    func shiftWeek(_ by: Int) {
        weekStart = SpaceTimetableLayout.calendar(zone).date(byAdding: .day, value: 7 * by, to: weekStart)!
        reload()
    }

    func goToToday() {
        weekStart = SpaceTimetableLayout.weekStart(containing: now(), zone: zone)
        reload()
    }

    var days: Int { max(1, dayStarts.count - 1) }

    static func format(_ pattern: String, _ date: Date, _ zone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_AU")
        f.timeZone = zone
        f.dateFormat = pattern
        return f.string(from: date)
    }

    /// "9:00 to 10:30", in the device's zone.
    func timeRange(_ start: Date, _ end: Date) -> String {
        Self.format("H:mm", start, zone) + " to " + Self.format("H:mm", end, zone)
    }

    /// The item's color: its first select or multi-select value by field order, else gray.
    func color(of record: PageRecord) -> FieldColor {
        guard let parent = store.pages[page] else { return .gray }
        for (id, def) in parent.fields.sorted(by: { ($0.value.order, $0.key) < ($1.value.order, $1.key) }) where def.type == .select || def.type == .multi {
            let option: String?
            switch record.props[id] {
            case .string(let s)?: option = s
            case .multi(let m)?: option = m.first
            default: option = nil
            }
            if let option, let c = def.options?[option]?.color { return c }
        }
        return .gray
    }

    /// The item's first nonempty text field by field order, like a room, as the slot's last line.
    func subtitle(of record: PageRecord) -> String? {
        guard let parent = store.pages[page] else { return nil }
        for (id, def) in parent.fields.sorted(by: { ($0.value.order, $0.key) < ($1.value.order, $1.key) }) where def.type == .text {
            if case .string(let s)? = record.props[id], !s.isEmpty { return s }
        }
        return nil
    }

    // MARK: Edits

    func commit(_ changes: [RecordChange], name: String) {
        guard let entry = store.edit(changes) else { return }
        // Explicit groups, like the editor's: one edit is one undo step, with or without an event loop.
        undo.beginUndoGrouping()
        register(UndoBox(entry), name: name)
        undo.endUndoGrouping()
    }

    private func register(_ box: UndoBox, name: String) {
        undo.registerUndo(withTarget: self) { $0.perform(box, name: name) }
        undo.setActionName(name)
    }

    private func perform(_ box: UndoBox, name: String) {
        guard let redo = store.undo(box.entry), !redo.isEmpty else { return }
        register(UndoBox(redo), name: name)
    }

    func performUndo() { if undo.canUndo { undo.undo() } }
    func performRedo() { if undo.canRedo { undo.redo() } }

    func setDate(_ item: PageID, _ value: DateValue, name: String) {
        guard let json = try? JSONValue(encoding: value) else { return }
        commit([RecordChange(kind: .page, id: item, set: ["props." + settings.field: json])], name: name)
    }

    /// Moves or resizes one occurrence; a weekly item's whole series follows.
    func move(_ slot: SpaceTimetableSlot, start: Date, end: Date, name: String) {
        guard case .date(let value)? = items[slot.item]?.props[settings.field],
              let moved = try? SpaceTimetableLayout.moved(value, occurrence: slot.occurrence, start: start, end: end, zone: zone),
              moved != value else { return }
        setDate(slot.item, moved, name: name)
    }

    /// A new item for a dragged range, last in the page's order, with an empty title to type into.
    @discardableResult
    func create(start: Date, end: Date) -> PageID? {
        ensureSettings()
        guard let value = try? SpaceTimetableLayout.created(start: start, end: end, zone: zone) else { return nil }
        let id = PageID()
        let last = store.content(of: page).last?.order
        var record = PageRecord(parent: page, order: (try? OrderKey.between(last, nil)) ?? (try! OrderKey.between(nil, nil)), created: SpaceClock.now())
        record.props[settings.field] = .date(value)
        guard let change = try? RecordChange.page(id, record) else { return nil }
        commit([change], name: "New item")
        return id
    }

    func rename(_ item: PageID, _ title: String) {
        guard let record = store.pages[item], record.title != title else { return }
        commit([RecordChange(kind: .page, id: item, set: ["title": .string(title)])], name: "Rename")
    }

    func toggleWeekly(_ item: PageID) {
        guard case .date(var value)? = items[item]?.props[settings.field] else { return }
        value.repeat = value.repeat == .weekly ? nil : .weekly
        setDate(item, value, name: value.repeat == nil ? "Stop repeating" : "Repeat weekly")
    }

    func trash(_ item: PageID) {
        commit([RecordChange(kind: .page, id: item, set: ["trashed": .bool(true), "trashedAt": .integer(SpaceClock.now())])], name: "Move to Trash")
    }

    // MARK: Layout and drawing

    var columnWidth: CGFloat { max(40, (bounds.width - 2 * Self.margin - Self.gutter) / CGFloat(days)) }
    private var toolbarY: CGFloat { (header?.frame.height ?? 186) - 30 }
    var dayHeaderY: CGFloat { toolbarY + 34 }
    var stripY: CGFloat { dayHeaderY + Self.dayHeader }
    var stripHeight: CGFloat { week.lanes == 0 ? 0 : CGFloat(week.lanes) * Self.lane + 4 }
    var gridY: CGFloat { stripY + stripHeight }

    func fitHeader() {
        guard let header, header.superview === superview, superview != nil else { return }
        let frame = NSRect(x: Self.margin, y: 0, width: max(0, bounds.width - 2 * Self.margin), height: header.frame.height)
        if header.frame != frame { header.frame = frame }
    }

    override func layout() {
        super.layout()
        fitHeader()
        let right = bounds.width - Self.margin
        let todayW = today.intrinsicContentSize.width
        today.frame = NSRect(x: right - todayW, y: toolbarY + 1, width: todayW, height: 24)
        next.frame = NSRect(x: today.frame.minX - 8 - 24, y: toolbarY + 1, width: 24, height: 24)
        let labelW = max(70, weekLabel.textWidth.rounded(.up) + 8)
        weekLabel.frame = NSRect(x: next.frame.minX - labelW, y: toolbarY + 4, width: labelW, height: 18)
        previous.frame = NSRect(x: weekLabel.frame.minX - 24, y: toolbarY + 1, width: 24, height: 24)
        scroll.frame = NSRect(x: 0, y: gridY, width: bounds.width, height: max(0, bounds.height - gridY))
        let docHeight = 24 * Self.hour + 16
        if grid.frame.size != NSSize(width: bounds.width, height: docHeight) {
            grid.frame = NSRect(x: 0, y: 0, width: bounds.width, height: docHeight)
            grid.needsDisplay = true
            window?.invalidateCursorRects(for: grid)
        }
        // Layer-backed views keep their old drawing through a resize, and the columns depend on the width.
        if bounds.size != drawnSize { drawnSize = bounds.size; needsDisplay = true }
        if !scrolledToStart, scroll.frame.height > 0 {
            scrolledToStart = true
            grid.scroll(NSPoint(x: 0, y: CGFloat(settings.from) * Self.hour))
        }
    }

    func dayX(_ day: Int) -> CGFloat { Self.margin + Self.gutter + CGFloat(day) * columnWidth }

    override var wantsUpdateLayer: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let todayStart = SpaceTimetableLayout.calendar(zone).startOfDay(for: now())
        for day in 0..<days {
            let isToday = dayStarts[day] == todayStart
            let s = NSMutableAttributedString(string: Self.format("EEE", dayStarts[day], zone) + "  ", attributes: [
                .font: DSFont.ui(13, weight: .medium), .foregroundColor: isToday ? Themed.color(\.primary) : Themed.color(\.mutedForeground)])
            s.append(NSAttributedString(string: Self.format("d", dayStarts[day], zone), attributes: [
                .font: DSFont.ui(13, weight: .semibold), .foregroundColor: isToday ? Themed.color(\.primary) : Themed.color(\.foreground)]))
            s.draw(at: NSPoint(x: dayX(day) + 10, y: dayHeaderY + 8))
        }
        for a in week.allDay {
            guard let record = items[a.item] else { continue }
            let r = NSRect(x: dayX(a.firstDay) + 4, y: stripY + 3 + CGFloat(a.lane) * Self.lane,
                           width: CGFloat(a.lastDay - a.firstDay + 1) * columnWidth - 8, height: 22)
            let c = color(of: record)
            SpaceTimetableColors.wash(c).setFill()
            NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
            Self.drawLine(record.title.isEmpty ? "Untitled" : record.title, in: r.insetBy(dx: 8, dy: 3), font: DSFont.ui(12, weight: .medium), color: SpaceTimetableColors.ink(c))
        }
        Themed.color(\.border).setFill()
        NSRect(x: Self.margin + Self.gutter, y: gridY - 1, width: CGFloat(days) * columnWidth, height: 1).fill()
    }

    static func drawLine(_ text: String, in rect: NSRect, font: NSFont, color: NSColor) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
            .draw(with: NSRect(x: rect.minX, y: rect.minY, width: max(0, rect.width), height: 16), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard event.clickCount == 2, p.y >= stripY, p.y < gridY else { return }
        let day = Int((p.x - dayX(0)) / columnWidth)
        let lane = Int((p.y - stripY - 3) / Self.lane)
        if let hit = week.allDay.first(where: { $0.lane == lane && (($0.firstDay)...($0.lastDay)).contains(day) }) { onOpenPage(hit.item) }
    }
}

/// The scrolling hours: lines, labels and slots, and the drags that create, move and resize.
final class SpaceTimetableGrid: DSView, NSTextFieldDelegate, NSUserInterfaceValidations {
    weak var owner: SpaceTimetableView?
    enum Drag {
        case create(day: Int, anchor: Int, current: Int)
        case move(SpaceTimetableSlot, origin: NSPoint, days: Int, minutes: Int)
        case resize(SpaceTimetableSlot, end: Int)
    }
    private(set) var drag: Drag?
    private(set) var selected: PageID?
    private var titleField: NSTextField?
    private var editing: PageID?
    private var moved = false

    override var acceptsFirstResponder: Bool { true }
    override var wantsUpdateLayer: Bool { false }

    private var hour: CGFloat { SpaceTimetableView.hour }
    private var top: CGFloat { 8 }

    func y(_ minute: Int) -> CGFloat { top + CGFloat(minute) / 60 * hour }
    func minute(_ y: CGFloat) -> Int { Int(((y - top) / hour * 60).rounded()) }

    func rect(_ slot: SpaceTimetableSlot) -> NSRect {
        guard let owner else { return .zero }
        let w = owner.columnWidth - 6
        let each = w / CGFloat(slot.columns)
        let x = owner.dayX(slot.day) + 3 + CGFloat(slot.column) * each
        let top = y(slot.startMinute) + 1
        let height = max(18, y(slot.endMinute) - y(slot.startMinute) - 2)
        return NSRect(x: x, y: top, width: each - (slot.column < slot.columns - 1 ? 2 : 0), height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let owner else { return }
        let days = owner.days
        let left = owner.dayX(0)
        let width = CGFloat(days) * owner.columnWidth
        let line = Themed.color(\.border)
        let label = Themed.color(\.secondaryLabel)
        let style = NSMutableParagraphStyle()
        style.alignment = .right
        for h in 0...24 {
            let yy = y(h * 60)
            line.setFill()
            NSRect(x: left, y: yy, width: width, height: 1).fill()
            if h < 24 {
                NSAttributedString(string: "\(h):00", attributes: [.font: DSFont.ui(11), .foregroundColor: label, .paragraphStyle: style])
                    .draw(in: NSRect(x: SpaceTimetableView.margin, y: yy - 7, width: SpaceTimetableView.gutter - 8, height: 14))
            }
        }
        for day in 0...days {
            line.setFill()
            NSRect(x: owner.dayX(day), y: top, width: 1, height: 24 * hour).fill()
        }
        let dragged: SpaceTimetableSlot? = {
            switch drag {
            case .move(let s, _, _, _)?, .resize(let s, _)?: return s
            default: return nil
            }
        }()
        for slot in owner.week.slots.sorted(by: { $0.column < $1.column }) {
            guard let record = owner.items[slot.item] else { continue }
            let isDragged = dragged.map { $0.item == slot.item && $0.occurrence == slot.occurrence } ?? false
            drawSlot(rect(slot), record: record, start: slot.start, end: slot.end, alpha: isDragged ? 0.35 : 1,
                     selected: selected == slot.item && !isDragged, hideTitle: editing == slot.item)
        }
        if let (r, start, end, record) = preview() {
            drawSlot(r, record: record, start: start, end: end, alpha: 1, selected: false)
        }
    }

    private func drawSlot(_ r: NSRect, record: PageRecord?, start: Date, end: Date, alpha: CGFloat, selected: Bool, hideTitle: Bool = false) {
        guard let owner, let ctx = NSGraphicsContext.current else { return }
        let color = record.map(owner.color(of:)) ?? .gray
        ctx.saveGraphicsState()
        ctx.cgContext.setAlpha(alpha)
        let path = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
        path.addClip()
        // An opaque base first, so a slot drawn over another reads cleanly.
        Themed.color(\.background).setFill()
        r.fill()
        SpaceTimetableColors.wash(color).setFill()
        r.fill()
        SpaceTimetableColors.ink(color).setFill()
        NSRect(x: r.minX, y: r.minY, width: 3, height: r.height).fill()
        if selected {
            SpaceTimetableColors.ink(color).setStroke()
            let ring = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 5.5, yRadius: 5.5)
            ring.lineWidth = 1
            ring.stroke()
        }
        let text = r.insetBy(dx: 8, dy: 5).offsetBy(dx: 1.5, dy: 0)
        let title = record.map { $0.title.isEmpty ? "Untitled" : $0.title } ?? ""
        let time = owner.timeRange(start, end)
        let sub = record.flatMap(owner.subtitle(of:))
        let lines = max(1, Int((text.height + 0.5) / 16))
        if !hideTitle {
            SpaceTimetableView.drawLine(title, in: text, font: DSFont.ui(12, weight: .semibold), color: SpaceTimetableColors.ink(color))
        }
        if lines >= 2 {
            let second = lines == 2 && sub != nil ? time + " · " + sub! : time
            SpaceTimetableView.drawLine(second, in: text.offsetBy(dx: 0, dy: 16), font: DSFont.ui(12), color: Themed.color(\.foreground, 0.82))
        }
        if lines >= 3, let sub {
            SpaceTimetableView.drawLine(sub, in: text.offsetBy(dx: 0, dy: 32), font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
        }
        ctx.restoreGraphicsState()
    }

    /// Where the dragged or new slot would land.
    private func preview() -> (NSRect, Date, Date, PageRecord?)? {
        guard let owner, let drag else { return nil }
        switch drag {
        case .create(let day, let anchor, let current):
            let (a, b) = (min(anchor, current), max(anchor, current))
            guard b > a else { return nil }
            let slot = SpaceTimetableSlot(item: PageID(), occurrence: 0, start: .distantPast, end: .distantPast, day: day, startMinute: a, endMinute: b)
            return (rect(slot), instant(day, a), instant(day, b), nil)
        case .move(let slot, _, let days, let minutes):
            guard moved, let (start, end) = target(slot, days: days, minutes: minutes) else { return nil }
            let startDay = dayIndex(start)
            guard startDay >= 0, startDay < owner.days else { return nil }
            let a = SpaceTimetableLayout.minute(of: start, dayStart: owner.dayStarts[startDay], zone: owner.zone)
            let b = SpaceTimetableLayout.minute(of: end, dayStart: owner.dayStarts[startDay], zone: owner.zone)
            var s = slot
            s.day = startDay; s.startMinute = a; s.endMinute = max(a + 15, b); s.column = 0; s.columns = 1
            return (rect(s), start, end, owner.items[slot.item])
        case .resize(let slot, let end):
            guard moved else { return nil }
            var s = slot
            s.endMinute = max(slot.startMinute + 15, end); s.column = 0; s.columns = 1
            return (rect(s), slot.start, instant(slot.day, s.endMinute), owner.items[slot.item])
        }
    }

    private func instant(_ day: Int, _ minute: Int) -> Date {
        guard let owner else { return Date() }
        let c = SpaceTimetableLayout.calendar(owner.zone)
        let d = day + Int((Double(minute) / 1440).rounded(.down))
        let m = ((minute % 1440) + 1440) % 1440
        return SpaceTimetableLayout.instant(day: c.date(byAdding: .day, value: d, to: owner.weekStart)!, minute: m, zone: owner.zone)
    }

    private func dayIndex(_ date: Date) -> Int {
        guard let owner else { return 0 }
        let c = SpaceTimetableLayout.calendar(owner.zone)
        return c.dateComponents([.day], from: owner.weekStart, to: c.startOfDay(for: date)).day ?? 0
    }

    /// A moved occurrence's new start and end: shifted by whole days and snapped minutes on the device's wall clock,
    /// keeping its length.
    func target(_ slot: SpaceTimetableSlot, days: Int, minutes: Int) -> (Date, Date)? {
        guard let owner else { return nil }
        let startDay = dayIndex(slot.start)
        let startMinute = SpaceTimetableLayout.minute(of: slot.start, dayStart: SpaceTimetableLayout.calendar(owner.zone).startOfDay(for: slot.start), zone: owner.zone)
        let snapped = Int((Double(startMinute + minutes) / 15).rounded()) * 15
        let start = instant(startDay + days, snapped)
        return (start, start.addingTimeInterval(slot.end.timeIntervalSince(slot.start)))
    }

    func hit(_ p: NSPoint) -> (SpaceTimetableSlot, edge: Bool)? {
        guard let owner else { return nil }
        for slot in owner.week.slots.sorted(by: { $0.column > $1.column }) {
            let r = rect(slot)
            if r.contains(p) { return (slot, !slot.clippedBottom && p.y > r.maxY - 6) }
        }
        return nil
    }

    func day(at x: CGFloat) -> Int? {
        guard let owner else { return nil }
        let d = Int(((x - owner.dayX(0)) / owner.columnWidth).rounded(.down))
        return d >= 0 && d < owner.days ? d : nil
    }

    override func resetCursorRects() {
        guard let owner else { return }
        for slot in owner.week.slots where !slot.clippedBottom {
            let r = rect(slot)
            addCursorRect(NSRect(x: r.minX, y: r.maxY - 6, width: r.width, height: 6), cursor: .resizeUpDown)
        }
    }

    override func mouseDown(with event: NSEvent) {
        endEditing()
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        moved = false
        if let (slot, edge) = hit(p) {
            selected = slot.item
            if event.clickCount == 2 { owner?.onOpenPage(slot.item); return }
            drag = edge ? .resize(slot, end: slot.endMinute) : .move(slot, origin: p, days: 0, minutes: 0)
        } else if let day = day(at: p.x) {
            selected = nil
            let m = SpaceTimetableLayout.snap(minute(p.y))
            drag = .create(day: day, anchor: m, current: m)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        autoscroll(with: event)
        let p = convert(event.locationInWindow, from: nil)
        guard let drag, let owner else { return }
        switch drag {
        case .create(let day, let anchor, _):
            self.drag = .create(day: day, anchor: anchor, current: SpaceTimetableLayout.snap(minute(p.y)))
            moved = true
        case .move(let slot, let origin, _, _):
            let days = Int(((p.x - origin.x) / owner.columnWidth).rounded())
            let minutes = Int(((p.y - origin.y) / hour * 60 / 15).rounded()) * 15
            if abs(p.x - origin.x) > 3 || abs(p.y - origin.y) > 3 { moved = true }
            self.drag = .move(slot, origin: origin, days: days, minutes: minutes)
        case .resize(let slot, _):
            self.drag = .resize(slot, end: SpaceTimetableLayout.snap(minute(p.y)))
            moved = true
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let owner, let drag else { return }
        self.drag = nil
        needsDisplay = true
        guard moved else { return }
        switch drag {
        case .create(let day, let anchor, let current):
            let (a, b) = (min(anchor, current), max(anchor, current))
            guard b > a, let id = owner.create(start: instant(day, a), end: instant(day, b)) else { return }
            selected = id
            beginEditing(id)
        case .move(let slot, _, let days, let minutes):
            guard let (start, end) = target(slot, days: days, minutes: minutes) else { return }
            owner.move(slot, start: start, end: end, name: "Move")
        case .resize(let slot, let end):
            let e = max(slot.startMinute + 15, end)
            owner.move(slot, start: slot.start, end: instant(slot.day, e), name: "Resize")
        }
        window?.invalidateCursorRects(for: self)
    }

    override func rightMouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let (slot, _) = hit(p), let owner else { return }
        selected = slot.item
        needsDisplay = true
        let menu = NSMenu()
        menu.autoenablesItems = false
        let weekly: Bool = { if case .date(let v)? = owner.items[slot.item]?.props[owner.settings.field] { return v.repeat == .weekly }; return false }()
        menu.addItem(SpaceTimetableMenuItem("Open") { [weak owner] in owner?.onOpenPage(slot.item) })
        menu.addItem(SpaceTimetableMenuItem("Rename") { [weak self] in self?.beginEditing(slot.item) })
        let repeatItem = SpaceTimetableMenuItem("Repeat weekly") { [weak owner] in owner?.toggleWeekly(slot.item) }
        repeatItem.state = weekly ? .on : .off
        menu.addItem(repeatItem)
        menu.addItem(.separator())
        menu.addItem(SpaceTimetableMenuItem("Move to Trash") { [weak owner] in owner?.trash(slot.item) })
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func keyDown(with event: NSEvent) {
        if let selected, event.keyCode == 51 || event.keyCode == 117 { owner?.trash(selected); self.selected = nil; return }
        if let selected, event.keyCode == 36 { beginEditing(selected); return }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, let owner else { return super.performKeyEquivalent(with: event) }
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        switch (mods, event.charactersIgnoringModifiers?.lowercased()) {
        case ([.command], "z"): owner.performUndo(); return true
        case ([.command, .shift], "z"): owner.performRedo(); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }

    @objc func undo(_ sender: Any?) { owner?.performUndo() }
    @objc func redo(_ sender: Any?) { owner?.performRedo() }

    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(undo(_:)) { return owner?.undo.canUndo ?? false }
        if item.action == #selector(redo(_:)) { return owner?.undo.canRedo ?? false }
        return true
    }

    // MARK: Title editing

    func beginEditing(_ item: PageID) {
        endEditing()
        guard let owner, let slot = owner.week.slots.first(where: { $0.item == item }) else { return }
        let r = rect(slot)
        let field = NSTextField(string: owner.items[item]?.title ?? "")
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = DSFont.ui(12, weight: .semibold)
        field.textColor = SpaceTimetableColors.ink(owner.items[item].map(owner.color(of:)) ?? .gray)
        field.placeholderString = "Untitled"
        field.cell?.usesSingleLineMode = true
        field.cell?.lineBreakMode = .byTruncatingTail
        field.delegate = self
        field.setAccessibilityLabel("Item title")
        field.frame = NSRect(x: r.minX + 9.5 - 2, y: r.minY + 4, width: max(20, r.width - 15), height: 18)
        addSubview(field)
        titleField = field
        editing = item
        needsDisplay = true
        window?.makeFirstResponder(field)
    }

    func endEditing() {
        guard let field = titleField, let item = editing else { return }
        titleField = nil
        editing = nil
        field.delegate = nil
        field.removeFromSuperview()
        owner?.rename(item, field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    func controlTextDidEndEditing(_ obj: Notification) { endEditing() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) || selector == #selector(NSResponder.cancelOperation(_:)) {
            endEditing()
            return true
        }
        return false
    }

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { "Timetable" }

    private var accessibilityCache: [NSAccessibilityElement]?
    func invalidateAccessibility() { accessibilityCache = nil }

    override func accessibilityChildren() -> [Any]? {
        if let accessibilityCache { return accessibilityCache }
        guard let owner else { return [] }
        let elements: [NSAccessibilityElement] = owner.week.slots.compactMap { slot in
            guard let record = owner.items[slot.item] else { return nil }
            let day = SpaceTimetableView.format("EEEE", owner.dayStarts[slot.day], owner.zone)
            let e = SpaceTimetableSlotElement()
            e.onPress = { [weak owner] in owner?.onOpenPage(slot.item) }
            e.setAccessibilityRole(.button)
            e.setAccessibilityLabel("\(record.title.isEmpty ? "Untitled" : record.title), \(day) \(owner.timeRange(slot.start, slot.end))")
            e.setAccessibilityParent(self)
            e.setAccessibilityFrameInParentSpace(rect(slot))
            return e
        }
        accessibilityCache = elements
        return elements
    }
}

final class SpaceTimetableSlotElement: NSAccessibilityElement {
    var onPress: () -> Void = {}
    override func accessibilityPerformPress() -> Bool { onPress(); return true }
}

final class SpaceTimetableMenuItem: NSMenuItem {
    private let run: () -> Void
    init(_ title: String, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    @available(*, unavailable) required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { run() }
}

/// Option colors for slots: a light wash and a stronger ink for the title and left edge, from mockup look A in dark
/// and a darker ink on a lighter wash in light.
enum SpaceTimetableColors {
    private static let dark: [String: UInt32] = ["gray": 0xa3a3a4, "brown": 0xc4a083, "orange": 0xe8a060, "yellow": 0xdcc060,
                                                 "green": 0x6cc08a, "blue": 0x74aeea, "purple": 0xb494e6, "pink": 0xe092be, "red": 0xf08a84]
    private static let light: [String: UInt32] = ["gray": 0x6b6b6e, "brown": 0x8a5a3c, "orange": 0xb85a14, "yellow": 0x8f6b00,
                                                  "green": 0x2f7d4a, "blue": 0x2a6cb5, "purple": 0x7448c2, "pink": 0xb03d7e, "red": 0xc0392f]
    nonisolated(unsafe) private static var cache: [String: NSColor] = [:]

    static func ink(_ c: FieldColor) -> NSColor { make(c, washed: false) }
    static func wash(_ c: FieldColor) -> NSColor { make(c, washed: true) }

    private static func make(_ c: FieldColor, washed: Bool) -> NSColor {
        let key = c.rawValue + (washed ? ".w" : ".i")
        if let hit = cache[key] { return hit }
        let name = dark[c.rawValue] == nil ? "gray" : c.rawValue
        func rgb(_ v: UInt32, _ a: CGFloat) -> NSColor {
            NSColor(srgbRed: CGFloat(v >> 16 & 0xff) / 255, green: CGFloat(v >> 8 & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: a)
        }
        let d = rgb(dark[name]!, washed ? 0.17 : 1)
        let l = rgb(washed ? dark[name]! : light[name]!, washed ? 0.22 : 1)
        let color = NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? d : l }
        cache[key] = color
        return color
    }
}
