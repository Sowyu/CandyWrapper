import AppKit
import SpaceEngine
import SpaceFields
import SpaceModel

/// The Table view's state and edits (docs/space.md "Table" and "View settings"). Rows are the page's items after the
/// view's sort and filter, columns are Title then `views.table.cols`. Every edit goes through `store.edit`, so it
/// saves encrypted, and registers on `undo`.
@MainActor
final class SpaceTableModel {
    struct Column: Equatable {
        /// A field id, or `FieldID.title`.
        var id: String
        var name: String
        /// Nil for the title.
        var type: FieldType?
        var width: CGFloat
        var isTitle: Bool { type == nil }
    }

    /// What a cell shows. Drawing reads this for visible rows only.
    enum Cell: Equatable {
        case empty
        case text(String)
        case link(String)
        case number(String)
        case checkbox(Bool)
        case options([FieldOption])
        case date(String, overdue: Bool)
        case files([BlobReference])
    }

    static let titleWidth: CGFloat = 280
    static let minWidth: CGFloat = 60
    static func defaultWidth(_ type: FieldType) -> CGFloat {
        switch type {
        case .number, .checkbox: 120
        case .select, .date: 150
        default: 200
        }
    }

    let store: SpaceDocumentStore
    let page: PageID
    let undo = UndoManager()
    var now: () -> Date = { Date() }
    var timeZone: () -> TimeZone = { .current }

    private(set) var record: PageRecord?
    private(set) var settings = TableViewSettings()
    private(set) var columns: [Column] = []
    private(set) var rows: [FieldItem] = []
    /// Sorts and filters that still name a field. A deleted field's leftovers are ignored, not thrown.
    private(set) var sorts: [Sort] = []
    private(set) var filters: [Filter] = []

    /// Runs after the model reloads for a store change that touched this page or its items.
    var onChange: () -> Void = {}
    private var rowIDs: Set<PageID> = []
    private var token: Int?

    init(store: SpaceDocumentStore, page: PageID) {
        self.store = store
        self.page = page
        undo.groupsByEvent = false
        reload()
        token = store.observe { [weak self] in self?.storeChanged() }
    }

    isolated deinit { if let token { store.removeObserver(token) } }

    /// Stores notify synchronously after every edit, including this model's own, so this is the one reload per edit.
    private func storeChanged() {
        let changed = store.lastChanged
        let pages = store.pages
        guard changed.contains(page) || changed.contains(where: { rowIDs.contains($0) || pages[$0]?.parent == page }) else { return }
        reload()
        onChange()
    }

    var fields: [String: FieldDefinition] { record?.fields ?? [:] }
    static let defaultTitleName = "Title"
    /// The title column's name, `titleName` on this page, shared by every view of its items.
    var titleName: String { record?.titleName.flatMap { $0.isEmpty ? nil : $0 } ?? Self.defaultTitleName }
    var titleHidden: Bool { settings.titleHidden }
    var context: FieldContext { FieldContext(now: now(), timeZone: timeZone()) }
    /// Field ids by field order, the order new tables and the Fields menu use.
    var fieldOrder: [String] {
        fields.sorted { $0.value.order == $1.value.order ? $0.key < $1.key : $0.value.order < $1.value.order }.map(\.key)
    }
    var canReorder: Bool { sorts.isEmpty }

    func reload() {
        guard let record = store.pages[page] else { record = nil; rows = []; rowIDs = []; columns = []; return }
        self.record = record
        let fields = record.fields
        settings = record.views.table ?? TableViewSettings()
        let known: (String) -> Bool = { $0 == FieldID.title || fields[$0] != nil }
        sorts = Array(settings.sort.filter { known($0.field) }.prefix(3))
        filters = settings.filter.filter { known($0.field) && (fields[$0.field].map { FieldFilters.operators(for: $0.type) } ?? [.contains, .doesNotContain, .is, .isEmpty, .isNotEmpty]).contains($0.op) }
        columns = settings.titleHidden ? [] : [Column(id: FieldID.title, name: titleName, type: nil,
                          width: settings.cols.first { $0.field == FieldID.title }.map { CGFloat($0.width) } ?? Self.titleWidth)]
        for col in visibleColumns() where col.field != FieldID.title {
            guard let f = fields[col.field] else { continue }
            columns.append(Column(id: col.field, name: f.name, type: f.type, width: max(Self.minWidth, CGFloat(col.width))))
        }
        // The query orders rows itself, so skip content(of:), which sorts blocks and pages together.
        let items = store.pages.compactMap { $0.value.parent == page && !$0.value.trashed ? FieldItem(id: $0.key, page: $0.value) : nil }
        rows = (try? FieldQuery.evaluate(items, fields: fields, sorts: sorts, filters: filters, context: context))
            ?? items.filter { !$0.page.trashed }
        rowIDs = Set(items.map(\.id))
    }

    /// `cols` when the table has settings, else every field in field order at its default width.
    private func visibleColumns() -> [TableColumn] {
        if record?.views.table != nil { return settings.cols }
        return fieldOrder.map { TableColumn(field: $0, width: Double(Self.defaultWidth(fields[$0]!.type))) }
    }

    // MARK: Reading cells

    func cell(_ row: Int, _ column: Column) -> Cell {
        let item = rows[row]
        if column.isTitle { return item.page.title.isEmpty ? .empty : .text(item.page.title) }
        guard let field = fields[column.id], let value = item.page.props[column.id] else { return .empty }
        switch (field.type, value) {
        case (.text, .string(let s)): return s.isEmpty ? .empty : .text(s)
        case (.url, .string(let s)): return s.isEmpty ? .empty : .link(Self.shortURL(s))
        case (.number, .number(let n)): return .number(NSDecimalNumber(decimal: n).stringValue)
        case (.checkbox, .checkbox(let b)): return .checkbox(b)
        case (.select, .string(let id)): return field.options?[id].map { .options([$0]) } ?? .empty
        case (.multi, .multi(let ids)):
            let opts = ids.compactMap { field.options?[$0] }
            return opts.isEmpty ? .empty : .options(opts.sorted { $0.order < $1.order })
        case (.date, .date(let d)):
            return .date(dateText(d), overdue: column.id == FieldID.due && !isDone(item) && isOverdue(d))
        case (.files, .files(let refs)): return refs.isEmpty ? .empty : .files(refs)
        default: return .empty
        }
    }

    /// A checkbox cell reads false when empty, so one click ticks it.
    func checked(_ row: Int, _ column: Column) -> Bool {
        if case .checkbox(true)? = rows[row].page.props[column.id] { return true }
        return false
    }

    private func isDone(_ item: FieldItem) -> Bool {
        if case .checkbox(true)? = item.page.props[FieldID.done] { return true }
        return false
    }

    /// The text the cell editor starts with.
    func editText(_ row: Int, _ column: Column) -> String {
        let item = rows[row]
        if column.isTitle { return item.page.title }
        switch item.page.props[column.id] {
        case .string(let s)?: return s
        case .number(let n)?: return NSDecimalNumber(decimal: n).stringValue
        default: return ""
        }
    }

    static func shortURL(_ s: String) -> String {
        var out = s
        for prefix in ["https://", "http://"] where out.hasPrefix(prefix) { out.removeFirst(prefix.count) }
        if out.hasPrefix("www.") { out.removeFirst(4) }
        return out
    }

    /// "Mon 27 Oct", with the time for a timed value in the device's zone, and the year when it isn't this year.
    func dateText(_ d: DateValue) -> String {
        let zone = timeZone()
        guard let instant = try? d.start.resolved(in: d.effectiveTimeZone(deviceTimeZone: zone)) else { return d.start.rawValue }
        let calendar = Self.calendar(zone)
        let sameYear = calendar.component(.year, from: instant) == calendar.component(.year, from: now())
        return Self.formatter((sameYear ? "EEE d MMM" : "EEE d MMM yyyy") + (d.start.isTimed ? " HH:mm" : ""), zone).string(from: instant)
    }

    /// The engine's overdue rule (docs/space-fields.md "Dates") for one value: a timed start has passed, or a
    /// date-only start's day has ended in the device's zone.
    func isOverdue(_ d: DateValue) -> Bool {
        let zone = timeZone()
        guard let start = try? d.start.resolved(in: d.effectiveTimeZone(deviceTimeZone: zone)) else { return false }
        if d.start.isTimed { return start < now() }
        guard let end = Self.calendar(zone).date(byAdding: .day, value: 1, to: start) else { return false }
        return end <= now()
    }

    private static var calendars: [String: Calendar] = [:]
    private static func calendar(_ zone: TimeZone) -> Calendar {
        if let c = calendars[zone.identifier] { return c }
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        calendars[zone.identifier] = c
        return c
    }

    /// Formatters by pattern and zone; making one costs more than drawing a row.
    private static var formatters: [String: DateFormatter] = [:]
    private static func formatter(_ pattern: String, _ zone: TimeZone) -> DateFormatter {
        let key = pattern + "|" + zone.identifier
        if let f = formatters[key] { return f }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_AU")
        f.timeZone = zone
        f.dateFormat = pattern
        formatters[key] = f
        return f
    }

    // MARK: Edits

    @discardableResult
    func commit(_ changes: [RecordChange], name: String) -> Bool {
        guard let entry = store.edit(changes) else { return false }
        register(UndoBox(entry), name: name)
        return true
    }

    private func register(_ box: UndoBox, name: String) {
        undo.beginUndoGrouping()
        undo.registerUndo(withTarget: self) { $0.perform(box) }
        undo.setActionName(name)
        undo.endUndoGrouping()
    }

    private func perform(_ box: UndoBox) {
        let redo = store.undo(box.entry)
        if let redo, !redo.isEmpty {
            let next = UndoBox(redo)
            undo.registerUndo(withTarget: self) { $0.perform(next) }
        }
    }

    private func pageChange(_ id: PageID, _ set: [String: JSONValue]) -> RecordChange { RecordChange(kind: .page, id: id, set: set) }
    private func json<T: Encodable>(_ value: T) -> JSONValue { (try? JSONValue(encoding: value)) ?? .null }

    /// Sets a cell from what the editor typed. Text that isn't a number leaves a number cell unchanged.
    @discardableResult
    func setText(_ row: Int, _ column: Column, _ text: String) -> Bool {
        let id = rows[row].id
        if column.isTitle {
            guard text != rows[row].page.title else { return false }
            return commit([pageChange(id, ["title": .string(text)])], name: "Rename")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let value: PropertyValue?
        switch column.type {
        case .number?:
            if trimmed.isEmpty { value = nil }
            else if let n = Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX")), trimmed.allSatisfy({ "0123456789.-+eE".contains($0) }) { value = .number(n) }
            else { return false }
        case .url?: value = trimmed.isEmpty ? nil : .string(trimmed)
        default: value = text.isEmpty ? nil : .string(text)
        }
        return setValue(row, column, value)
    }

    @discardableResult
    func setValue(_ row: Int, _ column: Column, _ value: PropertyValue?) -> Bool {
        guard !column.isTitle, rows.indices.contains(row) else { return false }
        guard rows[row].page.props[column.id] != value else { return false }
        return commit([pageChange(rows[row].id, ["props.\(column.id)": value.map(json) ?? .null])], name: "Edit \(column.name)")
    }

    func toggle(_ row: Int, _ column: Column) { setValue(row, column, .checkbox(!checked(row, column))) }

    func toggleOption(_ row: Int, _ column: Column, _ option: String) {
        guard let type = column.type else { return }
        if type == .select {
            if case .string(option)? = rows[row].page.props[column.id] { setValue(row, column, nil) } else { setValue(row, column, .string(option)) }
            return
        }
        var ids: [String] = []
        if case .multi(let current)? = rows[row].page.props[column.id] { ids = current }
        if let i = ids.firstIndex(of: option) { ids.remove(at: i) } else { ids.append(option) }
        setValue(row, column, ids.isEmpty ? nil : .multi(ids))
    }

    /// Adds an option to a select or multi field and picks it for the row, as one undo step.
    @discardableResult
    func addOption(_ name: String, to column: Column, pickFor row: Int?) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, var field = fields[column.id] else { return nil }
        var options = field.options ?? [:]
        if let existing = options.first(where: { $0.value.name.caseInsensitiveCompare(name) == .orderedSame }) {
            if let row { toggleOption(row, column, existing.key) }
            return existing.key
        }
        let id = Self.newID("o")
        let last = options.values.map(\.order).max()
        options[id] = FieldOption(name: name, color: Self.optionColor(options.count), order: Self.key(after: last))
        field.options = options
        var changes = [pageChange(page, ["fields.\(column.id)": json(field)])]
        if let row, rows.indices.contains(row) {
            let value: PropertyValue
            if field.type == .multi, case .multi(let ids)? = rows[row].page.props[column.id] { value = .multi(ids + [id]) }
            else { value = field.type == .multi ? .multi([id]) : .string(id) }
            changes.append(pageChange(rows[row].id, ["props.\(column.id)": json(value)]))
        }
        commit(changes, name: "Add option")
        return id
    }

    /// A new item after the page's last content. A to-do list's items start unticked. Returns its row, if it shows.
    @discardableResult
    func addRow(title: String = "") -> PageID? {
        let last = store.content(of: page).last?.order
        let id = PageID()
        var record = PageRecord(parent: page, order: Self.key(after: last), title: title, created: SpaceClock.now())
        if fields[FieldID.done] != nil { record.props[FieldID.done] = .checkbox(false) }
        guard let change = try? RecordChange.page(id, record), commit([change], name: "New row") else { return nil }
        return id
    }

    /// Moves a row before another row, or to the end, in the page's manual order. Off while a sort is on.
    @discardableResult
    func moveRow(_ id: PageID, before target: PageID?) -> Bool {
        guard canReorder, id != target else { return false }
        let content = store.content(of: page).filter { $0.id != id }
        let index = target.flatMap { t in content.firstIndex { $0.id == t } } ?? content.count
        let lower = index > 0 ? content[index - 1].order : nil
        let upper = index < content.count ? content[index].order : nil
        guard let key = try? OrderKey.between(lower, upper == lower ? nil : upper) else { return false }
        return commit([pageChange(id, ["order": .string(key.rawValue)])], name: "Move row")
    }

    func trashRow(_ row: Int) {
        commit([pageChange(rows[row].id, ["trashed": .bool(true), "trashedAt": .integer(SpaceClock.now())])], name: "Delete row")
    }

    // MARK: Fields and settings

    /// Writes `views.table` alone, so Board and Timetable settings edited elsewhere merge.
    private func settingsChange(_ s: TableViewSettings) -> RecordChange { pageChange(page, ["views.table": json(s)]) }
    /// The settings with `cols` written out, so a first edit keeps the columns the table showed.
    private var materialized: TableViewSettings {
        var s = settings
        // A hidden title keeps the width it had for when it shows again.
        let hiddenTitle = settings.titleHidden ? settings.cols.filter { $0.field == FieldID.title } : []
        s.cols = hiddenTitle + columns.filter { !$0.isTitle || $0.width != Self.titleWidth }.map { TableColumn(field: $0.id, width: Double($0.width)) }
        s.sort = sorts
        s.filter = filters
        return s
    }

    func defaultName(_ type: FieldType) -> String {
        let base: String = switch type {
        case .number: "Number"
        case .checkbox: "Checkbox"
        case .select: "Select"
        case .multi: "Tags"
        case .date: "Date"
        case .url: "Link"
        case .files: "Files & media"
        default: "Text"
        }
        let names = Set(fields.values.map(\.name))
        if !names.contains(base) { return base }
        return (2...).lazy.map { "\(base) \($0)" }.first { !names.contains($0) }!
    }

    /// Adds a field and its column at the end. Returns the field id.
    @discardableResult
    func addField(_ type: FieldType, name: String? = nil) -> String? {
        let id = Self.newID("f")
        let field = FieldDefinition(name: name ?? defaultName(type), type: type, order: Self.key(after: fields.values.map(\.order).max()),
                                    options: [.select, .multi].contains(type) ? [:] : nil)
        var s = materialized
        s.cols.append(TableColumn(field: id, width: Double(Self.defaultWidth(type))))
        return commit([pageChange(page, ["fields.\(id)": json(field)]), settingsChange(s)], name: "Add field") ? id : nil
    }

    func renameField(_ id: String, _ name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if id == FieldID.title {
            guard !name.isEmpty, name != titleName else { return }
            commit([pageChange(page, ["titleName": name == Self.defaultTitleName ? .null : .string(name)])], name: "Rename field")
            return
        }
        guard !name.isEmpty, var field = fields[id], field.name != name else { return }
        field.name = name
        commit([pageChange(page, ["fields.\(id)": json(field)])], name: "Rename field")
    }

    /// Changing a field's type, previewed: `lost` counts values that won't survive, for the confirmation.
    struct TypeChange {
        var plan: FieldConversionPlan
        var lost: Int { plan.lostValueCount }
    }

    /// Text and URL to select or multi first adds an option for each distinct value, so values convert by name.
    func previewType(_ id: String, to type: FieldType) -> TypeChange? {
        guard let source = fields[id], source.type != type, id != FieldID.done, id != FieldID.due else { return nil }
        let items = store.pages.filter { $0.value.parent == page }.map { FieldItem(id: $0.key, page: $0.value) }
        var target = FieldDefinition(name: source.name, type: type, order: source.order, options: source.options, extra: source.extra)
        if [.select, .multi].contains(type) {
            var options = source.options ?? [:]
            if ![.select, .multi].contains(source.type) {
                var seen = Set(options.values.map { $0.name.lowercased() })
                var last = options.values.map(\.order).max()
                for item in items.sorted(by: { $0.page.order < $1.page.order }) {
                    guard let value = item.page.props[id] else { continue }
                    let name: String
                    switch value {
                    case .string(let s): name = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    case .number(let n): name = NSDecimalNumber(decimal: n).stringValue
                    case .checkbox(let b): name = b ? "true" : "false"
                    case .date(let d): name = d.start.rawValue
                    default: continue
                    }
                    guard !name.isEmpty, seen.insert(name.lowercased()).inserted else { continue }
                    let order = Self.key(after: last)
                    last = order
                    options[Self.newID("o")] = FieldOption(name: name, color: Self.optionColor(options.count), order: order)
                }
            }
            target.options = options
        } else {
            target.options = nil
        }
        guard let plan = try? FieldConversion.preview(items, fieldID: id, source: source, target: target, context: context) else { return nil }
        return TypeChange(plan: plan)
    }

    func applyType(_ change: TypeChange) {
        let id = change.plan.fieldID
        var changes = [pageChange(page, ["fields.\(id)": json(change.plan.target)])]
        for item in change.plan.items where item.result.outcome != .kept && item.result.outcome != .empty {
            changes.append(pageChange(item.id, ["props.\(id)": item.result.value.map(json) ?? .null]))
        }
        var s = materialized
        if let i = s.cols.firstIndex(where: { $0.field == id }) { s.cols[i].width = Double(max(CGFloat(s.cols[i].width), Self.minWidth)) }
        // Filters keep only operators the new type has; sorts still apply to any type.
        s.filter = s.filter.filter { $0.field != id }
        changes.append(settingsChange(s))
        commit(changes, name: "Change type")
    }

    /// Removes the field and its column, sorts and filters. Values stay on the items, so undo brings everything back.
    func deleteField(_ id: String) {
        guard fields[id] != nil else { return }
        var s = materialized
        s.cols.removeAll { $0.field == id }
        s.sort.removeAll { $0.field == id }
        s.filter.removeAll { $0.field == id }
        commit([pageChange(page, ["fields.\(id)": .null]), settingsChange(s)], name: "Delete field")
    }

    /// The title hides in this view only. It can't be deleted, since every row is a page with a title.
    func setHidden(_ id: String, _ hidden: Bool) {
        if id == FieldID.title {
            guard hidden != settings.titleHidden else { return }
            var s = materialized
            s.titleHidden = hidden
            commit([settingsChange(s)], name: hidden ? "Hide field" : "Show field")
            return
        }
        guard let type = fields[id]?.type else { return }
        var s = materialized
        if hidden { s.cols.removeAll { $0.field == id } }
        else if !s.cols.contains(where: { $0.field == id }) { s.cols.append(TableColumn(field: id, width: Double(Self.defaultWidth(type)))) }
        commit([settingsChange(s)], name: hidden ? "Hide field" : "Show field")
    }

    func resize(_ id: String, to width: CGFloat) {
        var s = materialized
        let w = Double(max(Self.minWidth, width.rounded()))
        if let i = s.cols.firstIndex(where: { $0.field == id }) { s.cols[i].width = w }
        else if id == FieldID.title { s.cols.insert(TableColumn(field: id, width: w), at: 0) }
        commit([settingsChange(s)], name: "Resize column")
    }

    /// Sorting from a header replaces the sort with that field alone.
    func sort(by id: String, desc: Bool) {
        var s = materialized
        s.sort = [Sort(field: id, desc: desc)]
        commit([settingsChange(s)], name: "Sort")
    }

    /// Adds a sort after the others, up to three; a field already sorted changes direction.
    func addSort(_ id: String, desc: Bool) {
        var s = materialized
        if let i = s.sort.firstIndex(where: { $0.field == id }) { s.sort[i].desc = desc }
        else if s.sort.count < 3 { s.sort.append(Sort(field: id, desc: desc)) }
        else { return }
        commit([settingsChange(s)], name: "Sort")
    }

    func removeSort(_ index: Int) {
        var s = materialized
        guard s.sort.indices.contains(index) else { return }
        s.sort.remove(at: index)
        commit([settingsChange(s)], name: "Remove sort")
    }

    func clearSort() {
        var s = materialized
        guard !s.sort.isEmpty else { return }
        s.sort = []
        commit([settingsChange(s)], name: "Clear sort")
    }

    func addFilter(_ filter: Filter) {
        var s = materialized
        s.filter.append(filter)
        commit([settingsChange(s)], name: "Filter")
    }

    func removeFilter(_ index: Int) {
        var s = materialized
        guard s.filter.indices.contains(index) else { return }
        s.filter.remove(at: index)
        commit([settingsChange(s)], name: "Remove filter")
    }

    func name(of id: String) -> String { id == FieldID.title ? titleName : fields[id]?.name ?? id }

    // MARK: Files and icons

    func files(_ row: Int, _ column: Column) -> [BlobReference] {
        guard rows.indices.contains(row), case .files(let refs)? = rows[row].page.props[column.id] else { return [] }
        return refs
    }

    func addFiles(_ row: Int, _ column: Column, _ refs: [BlobReference]) {
        guard rows.indices.contains(row) else { return }
        addFiles(to: rows[row].id, field: column.id, refs)
    }

    /// By page id, so an upload that finishes after its row was filtered out or sorted away still lands.
    func addFiles(to id: PageID, field: String, _ refs: [BlobReference]) {
        guard let item = store.pages[id], item.parent == page, fields[field]?.type == .files, !refs.isEmpty else { return }
        var old: [BlobReference] = []
        if case .files(let current)? = item.props[field] { old = current }
        let added = refs.filter { r in !old.contains { $0.id == r.id } }
        guard !added.isEmpty else { return }
        commit([pageChange(id, ["props.\(field)": json(PropertyValue.files(old + added))])], name: "Edit \(name(of: field))")
    }

    func removeFile(_ row: Int, _ column: Column, at index: Int) {
        var refs = files(row, column)
        guard refs.indices.contains(index) else { return }
        refs.remove(at: index)
        setValue(row, column, refs.isEmpty ? nil : .files(refs))
    }

    func setIcon(_ row: Int, _ choice: SpacePageIcon.Choice) {
        guard rows.indices.contains(row) else { return }
        setIcon(of: rows[row].id, choice)
    }

    func setIcon(of id: PageID, _ choice: SpacePageIcon.Choice) {
        guard store.pages[id]?.parent == page else { return }
        commit([SpacePageIcon.change(id, choice)], name: "Icon")
    }

    /// "Course is MATH2221", "Due this week", "Weight ≥ 10".
    func describe(_ f: Filter) -> String {
        let field = name(of: f.field)
        let value: String
        switch f.value {
        case .string(let s): value = fields[f.field]?.options?[s]?.name ?? s
        case .number(let n): value = NSDecimalNumber(decimal: n).stringValue
        case .integer(let n): value = String(n)
        case .bool(let b): value = b ? "checked" : "unchecked"
        default: value = ""
        }
        if [.isEmpty, .isNotEmpty, .thisWeek, .overdue].contains(f.op) { return "\(field) \(f.op.rawValue)" }
        return "\(field) \(f.op.rawValue) \(value)"
    }

    // MARK: Ids and keys

    static func newID(_ prefix: String) -> String {
        let digits = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        return prefix + String((0..<7).map { _ in digits.randomElement()! })
    }

    /// New options take distinct colors, gray last.
    static func optionColor(_ index: Int) -> FieldColor {
        let cycle: [FieldColor] = [.blue, .purple, .green, .orange, .pink, .yellow, .red, .brown, .gray]
        return cycle[index % cycle.count]
    }

    static func key(after last: OrderKey?) -> OrderKey { (try? OrderKey.between(last, nil)) ?? (try! OrderKey.between(nil, nil)) }
}
