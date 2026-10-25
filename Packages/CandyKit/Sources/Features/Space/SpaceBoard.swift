import Foundation
import SpaceFields
import SpaceModel

/// One Board column: an option of the group field, a checkbox value, or "No <field>".
struct SpaceBoardColumn: Equatable {
    var key: FieldGroupKey
    var title: String
    var color: FieldColor
    var cards: [PageID]
}

/// What a card shows besides its title: the `show` fields as one muted line, then the due date.
struct SpaceBoardCard: Equatable {
    var title: String
    var meta: String
    var due: (text: String, late: Bool)?
    var todo: Bool
    var done: Bool
    var icon: SpacePageIcon.Choice = .none

    static func == (a: Self, b: Self) -> Bool {
        a.icon == b.icon && a.title == b.title && a.meta == b.meta && a.due?.text == b.due?.text && a.due?.late == b.due?.late && a.todo == b.todo && a.done == b.done
    }
}

/// Board's rules (docs/space.md section 4, "Board") as pure functions over records. Every write comes back as
/// `RecordChange`s for the store's `edit`, so it goes through apply, saves encrypted and undoes.
@MainActor
enum SpaceBoard {
    static let groupTypes: Set<FieldType> = [.select, .multi, .checkbox]
    static let statusOptions = [("Not started", FieldColor.gray), ("In progress", .blue), ("Done", .green)]

    /// The group field Board uses, when the settings name one that can group.
    static func groupField(_ record: PageRecord) -> (id: String, field: FieldDefinition)? {
        guard let id = record.views.board?.group, let field = record.fields[id], groupTypes.contains(field.type) else { return nil }
        return (id, field)
    }

    /// The change that lets Board open `page`: settings grouping by the first select field, and a "Status" select
    /// with Not started, In progress and Done when there's none. Nil when the settings already work.
    static func setup(_ page: PageID, _ record: PageRecord, newID: () -> String = { UUID().uuidString.lowercased() }) -> RecordChange? {
        if groupField(record) != nil { return nil }
        var set: [String: JSONValue] = [:]
        let byOrder = record.fields.sorted { ($0.value.order, $0.key) < ($1.value.order, $1.key) }
        var group = byOrder.first { $0.value.type == .select }?.key
        if group == nil {
            let id = newID()
            var options: [String: FieldOption] = [:]
            var last: OrderKey?
            for (name, color) in statusOptions {
                let order = try! OrderKey.between(last, nil)
                options[newID()] = FieldOption(name: name, color: color, order: order)
                last = order
            }
            let order = try! OrderKey.between(byOrder.map(\.value.order).max(), nil)
            set["fields." + id] = encode(FieldDefinition(name: "Status", type: .select, order: order, options: options))
            group = id
        }
        var settings = record.views.board ?? BoardViewSettings(group: group!)
        settings.group = group!
        if record.views.board == nil {
            // Up to three other fields fill the card's muted line until the user picks.
            settings.show = byOrder.filter { $0.key != group && $0.key != FieldID.done && $0.key != FieldID.due && $0.value.type != .checkbox }.prefix(3).map(\.key)
        }
        set["views.board"] = encode(settings)
        return RecordChange(kind: .page, id: page, set: set)
    }

    /// The columns for `page`'s child pages, filtered and sorted by the board settings. Empty when Board can't group.
    static func columns(_ record: PageRecord, items: [(PageID, PageRecord)], context: FieldContext) -> [SpaceBoardColumn] {
        guard let (groupID, field) = groupField(record), let settings = record.views.board else { return [] }
        var input = items.map { FieldItem(id: $0.0, page: $0.1) }
        // A card without a checkbox value reads as unticked, so a checkbox board has just its two columns.
        if field.type == .checkbox {
            for i in input.indices where input[i].page.props[groupID] == nil { input[i].page.props[groupID] = .checkbox(false) }
        }
        // A filter or sort that names a field that's gone shows the cards unfiltered rather than an empty board.
        let rows = (try? FieldQuery.evaluate(input, fields: record.fields, sorts: settings.sort, filters: settings.filter, context: context))
            ?? (try? FieldQuery.evaluate(input, fields: record.fields, context: context)) ?? []
        guard let groups = try? FieldQuery.groups(rows, field: field, fieldID: groupID, hiddenOptions: Set(settings.hidden)) else { return [] }
        return groups.map { g in
            let cards = g.items.map(\.id)
            switch g.key {
            case .empty: return SpaceBoardColumn(key: g.key, title: "No " + field.name, color: .gray, cards: cards)
            case .checkbox(let on): return SpaceBoardColumn(key: g.key, title: on ? field.name : "Not " + field.name.lowercased(), color: on ? .green : .gray, cards: cards)
            case .option(let id):
                let option = field.options?[id]
                return SpaceBoardColumn(key: g.key, title: option?.name ?? "", color: option?.color ?? .gray, cards: cards)
            }
        }
    }

    /// The card's text. `now` and `zone` come from the device, as the fields engine needs.
    static func card(_ record: PageRecord, schema: PageRecord, now: Date = Date(), zone: TimeZone = .current) -> SpaceBoardCard {
        let show = schema.views.board?.show ?? []
        let meta = show.prefix(3).compactMap { id -> String? in
            guard let field = schema.fields[id], let value = record.props[id] else { return nil }
            return text(value, field)
        }.joined(separator: " · ")
        var p = SpaceParagraph()
        if case .checkbox(let v)? = record.props[FieldID.done] { p.todo = true; p.done = v }
        if case .date(let due)? = record.props[FieldID.due] { p.due = due }
        return SpaceBoardCard(title: record.title, meta: meta, due: SpacePageEditor.dueText(p, now: now, zone: zone), todo: schema.isTodoList && p.todo, done: p.done,
                             icon: SpacePageIcon.choice(record))
    }

    /// One prop as card text, or nil when it's empty.
    static func text(_ value: PropertyValue, _ field: FieldDefinition) -> String? {
        let s: String
        switch (field.type, value) {
        case (.select, .string(let id)): s = field.options?[id]?.name ?? ""
        case (.multi, .multi(let ids)): s = ids.compactMap { field.options?[$0]?.name }.joined(separator: ", ")
        case (.checkbox, .checkbox(let on)): s = on ? field.name : ""
        case (.number, .number(let n)): s = "\(n)"
        case (.date, .date(let d)):
            var p = SpaceParagraph()
            p.due = d
            p.done = true
            s = SpacePageEditor.dueText(p)?.text ?? ""
        case (.text, .string(let t)), (.url, .string(let t)): s = t
        default: s = ""
        }
        return s.isEmpty ? nil : s
    }

    // MARK: Moves

    /// The changes that drop `card` into `column` before `before`, or at the column's end for nil.
    /// The group value changes when the column does; the order changes only without a sort, as section 4 says.
    static func move(_ card: PageID, from: FieldGroupKey, to column: SpaceBoardColumn, before: PageID?,
                     page: PageID, record: PageRecord, content: [SpaceContent]) -> RecordChange? {
        guard let (groupID, field) = groupField(record), let current = content.first(where: { $0.id == card }),
              case .page(_, let cardRecord) = current else { return nil }
        var set: [String: JSONValue] = [:]
        if from != column.key { set["props." + groupID] = value(moving: cardRecord.props[groupID], from: from, to: column.key, field) }
        if record.views.board?.sort.isEmpty ?? true, let order = order(for: card, before: before, in: column, content: content) {
            set["order"] = .string(order.rawValue)
        }
        return set.isEmpty ? nil : RecordChange(kind: .page, id: card, set: set)
    }

    /// The group value after a move. A multi-select card swaps the source option for the target one.
    static func value(moving old: PropertyValue?, from: FieldGroupKey, to: FieldGroupKey, _ field: FieldDefinition) -> JSONValue {
        switch to {
        case .empty: return field.type == .multi ? .array([]) : .null
        case .checkbox(let on): return .bool(on)
        case .option(let id):
            guard field.type == .multi else { return .string(id) }
            var ids: [String] = []
            if case .multi(let old)? = old { ids = old }
            if case .option(let source) = from { ids.removeAll { $0 == source } }
            if !ids.contains(id) { ids.append(id) }
            return .array(ids.map(JSONValue.string))
        }
    }

    /// A key that puts `card` before `before` in the page's content, or right after the column's last other card.
    /// Nil when the column has no other card, since any order lands there.
    static func order(for card: PageID, before: PageID?, in column: SpaceBoardColumn, content: [SpaceContent]) -> OrderKey? {
        let others = content.filter { $0.id != card }
        let index: Int
        if let before, let i = others.firstIndex(where: { $0.id == before }) {
            index = i
        } else if let last = column.cards.last(where: { $0 != card }), let i = others.firstIndex(where: { $0.id == last }) {
            index = i + 1
        } else { return nil }
        return between(index > 0 ? others[index - 1].order : nil, index < others.count ? others[index].order : nil)
    }

    /// A key between two neighbors. Equal keys only come from other clients; the id breaks that tie, so the lower one works.
    static func between(_ lower: OrderKey?, _ upper: OrderKey?) -> OrderKey {
        (try? OrderKey.between(lower, upper == lower ? nil : upper)) ?? (try! OrderKey.between(lower, nil))
    }

    // MARK: Cards and options

    /// A new card at the end of `column`, with the column's group value. A to-do list's card starts not done.
    static func newCard(_ id: PageID, in column: SpaceBoardColumn, page: PageID, record: PageRecord, content: [SpaceContent],
                        now: Int64) -> RecordChange? {
        guard let (groupID, field) = groupField(record) else { return nil }
        let order = order(for: id, before: nil, in: column, content: content) ?? between(content.last?.order, nil)
        var props: [String: PropertyValue] = [:]
        switch value(moving: nil, from: .empty, to: column.key, field) {
        case .string(let s): props[groupID] = .string(s)
        case .bool(let b): props[groupID] = .checkbox(b)
        case .array(let a): if !a.isEmpty { props[groupID] = .multi(a.compactMap { if case .string(let s) = $0 { s } else { nil } }) }
        default: break
        }
        if record.isTodoList, groupID != FieldID.done { props[FieldID.done] = .checkbox(false) }
        let card = PageRecord(parent: page, order: order, props: props, created: now)
        guard case .object(let object)? = try? JSONValue(encoding: card) else { return nil }
        return RecordChange(kind: .page, id: id, set: object)
    }

    /// The group field with `change` applied to its options, as one `fields.<id>` change.
    static func editOptions(_ page: PageID, _ record: PageRecord, _ change: (inout [String: FieldOption]) -> Void) -> RecordChange? {
        guard let (groupID, found) = groupField(record), found.type != .checkbox else { return nil }
        var field = found
        var options = field.options ?? [:]
        change(&options)
        field.options = options
        return RecordChange(kind: .page, id: page, set: ["fields." + groupID: encode(field)])
    }

    /// A new option after the last one, in the first color no option uses yet.
    static func addOption(_ id: String, name: String, page: PageID, record: PageRecord) -> RecordChange? {
        editOptions(page, record) { options in
            let used = Set(options.values.map(\.color))
            let color = FieldColor.allCases.first { !used.contains($0) } ?? .gray
            options[id] = FieldOption(name: name, color: color, order: between(options.values.map(\.order).max(), nil))
        }
    }

    /// Deletes an option and clears it from every card that had it, in one change so undo brings both back.
    static func deleteOption(_ id: String, page: PageID, record: PageRecord, items: [(PageID, PageRecord)]) -> [RecordChange] {
        guard let (groupID, _) = groupField(record), let fieldChange = editOptions(page, record, { $0[id] = nil }) else { return [] }
        var changes = [fieldChange]
        if var settings = record.views.board, settings.hidden.contains(id) {
            settings.hidden.removeAll { $0 == id }
            changes[0].set["views.board"] = encode(settings)
        }
        for (cid, r) in items {
            switch r.props[groupID] {
            case .string(id)?: changes.append(RecordChange(kind: .page, id: cid, set: ["props." + groupID: .null]))
            case .multi(let ids)? where ids.contains(id):
                changes.append(RecordChange(kind: .page, id: cid, set: ["props." + groupID: .array(ids.filter { $0 != id }.map(JSONValue.string))]))
            default: break
            }
        }
        return changes
    }

    /// Board settings with `change` applied, as one `views.board` change.
    static func editSettings(_ page: PageID, _ record: PageRecord, _ change: (inout BoardViewSettings) -> Void) -> RecordChange? {
        guard var settings = record.views.board else { return nil }
        change(&settings)
        return RecordChange(kind: .page, id: page, set: ["views.board": encode(settings)])
    }

    static func encode<T: Encodable>(_ value: T) -> JSONValue { (try? JSONValue(encoding: value)) ?? .null }
}
