import Foundation
import SpaceModel

public enum FieldGroupKey: Hashable, Sendable {
    case empty
    case option(String)
    case checkbox(Bool)
}

public struct FieldGroup: Equatable, Sendable {
    public var key: FieldGroupKey
    public var items: [FieldItem]
}

public enum FieldQuery {
    /// Items must be the parent's child pages. Trash is excluded; records are never mutated.
    /// Comparisons are prepared once per cell, including date resolution and Unicode folding.
    public static func evaluate(_ items: [FieldItem], fields: [String: FieldDefinition],
                                sorts: [Sort] = [], filters: [Filter] = [],
                                context: FieldContext) throws -> [FieldItem] {
        guard sorts.count <= 3 else { throw FieldEngineError.tooManySorts }
        let sortFields = try sorts.map { sort in
            let field = try definition(sort.field, fields: fields)
            let options = orderedOptions(field)
            return (field: field, options: options, ranks: Dictionary(uniqueKeysWithValues: options.enumerated().map { ($0.element, $0.offset) }))
        }
        let predicates = try filters.map { try CompiledFilter($0, fields: fields) }
        let rows = try items.filter { item in
            guard !item.page.trashed else { return false }
            for predicate in predicates where try !predicate.matches(item, context: context) { return false }
            return true
        }.map { item in
            let keys = try zip(sorts, sortFields).map { sort, schema in
                try SortKey.make(Cell.read(property(item, fieldID: sort.field), field: schema.field, optionOrder: schema.options),
                                 optionRanks: schema.ranks, context: context)
            }
            return (item: item, keys: keys)
        }
        return rows.sorted { lhs, rhs in
            for index in sorts.indices {
                let a = lhs.keys[index], b = rhs.keys[index]
                // Empty cells stay last in both directions.
                if a == nil && b != nil { return false }
                if a != nil && b == nil { return true }
                if let a, let b, a != b { return sorts[index].desc ? b < a : a < b }
            }
            if lhs.item.page.order != rhs.item.page.order { return lhs.item.page.order < rhs.item.page.order }
            return lhs.item.id < rhs.item.id
        }.map(\.item)
    }

    /// Group already queried items so filters and each column share the same ordering.
    /// Multi-select cards belong to every selected column. Hiding a column never rewrites a card.
    public static func groups(_ items: [FieldItem], field: FieldDefinition,
                              fieldID: String, hiddenOptions: Set<String> = []) throws -> [FieldGroup] {
        guard [.select, .multi, .checkbox].contains(field.type) else {
            throw FieldEngineError.cannotGroup(field.type)
        }
        let options = orderedOptions(field)
        var buckets: [FieldGroupKey: [FieldItem]] = [:]
        for item in items where !item.page.trashed {
            let keys: [FieldGroupKey]
            switch Cell.read(item.page.props[fieldID], field: field, optionOrder: options) {
            case .options(let ids): keys = ids.map(FieldGroupKey.option)
            case .checkbox(let value): keys = [.checkbox(value)]
            default: keys = [.empty]
            }
            for key in keys { buckets[key, default: []].append(item) }
        }
        let columns: [FieldGroupKey] = field.type == .checkbox
            ? [.checkbox(false), .checkbox(true)]
            : options.filter { !hiddenOptions.contains($0) }.map(FieldGroupKey.option)
        let keys: [FieldGroupKey] = (buckets[.empty] == nil ? [] : [.empty]) + columns
        return keys.map { FieldGroup(key: $0, items: buckets[$0] ?? []) }
    }
}

private enum SortKey: Equatable, Comparable {
    case text(String), number(Decimal), checkbox(Bool), options([Int]), date(Date)

    static func make(_ cell: Cell?, optionRanks: [String: Int], context: FieldContext) throws -> Self? {
        switch cell {
        case .text(let text): return .text(folded(text))
        case .number(let number): return .number(number)
        case .checkbox(let value): return .checkbox(value)
        case .options(let ids):
            return .options(ids.compactMap { optionRanks[$0] })
        case .date(let date):
            return .date(try date.start.resolved(in: date.effectiveTimeZone(deviceTimeZone: context.timeZone)))
        case nil: return nil
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.text(let a), .text(let b)): return byteLess(a, b)
        case (.number(let a), .number(let b)): return a < b
        case (.checkbox(let a), .checkbox(let b)): return !a && b
        case (.options(let a), .options(let b)): return a.lexicographicallyPrecedes(b)
        case (.date(let a), .date(let b)): return a < b
        default: return false // A sort column always has one schema and one key kind.
        }
    }
}
