import Foundation
import SpaceModel

public enum FieldFilters {
    public static func operators(for type: FieldType) -> [FilterOp] {
        switch type {
        case .text, .url: return [.contains, .doesNotContain, .is, .isEmpty, .isNotEmpty]
        case .number: return [.eq, .ne, .lt, .le, .gt, .ge, .isEmpty]
        case .checkbox: return [.is]
        case .select, .multi: return [.is, .isNot, .isEmpty]
        case .files: return [.isEmpty, .isNotEmpty]
        case .date: return [.before, .after, .on, .thisWeek, .overdue, .isEmpty]
        default: return []
        }
    }

    public static func matches(_ item: FieldItem, filter: Filter, fields: [String: FieldDefinition],
                               context: FieldContext) throws -> Bool {
        try CompiledFilter(filter, fields: fields).matches(item, context: context)
    }
}

// Compile and validate even for an empty item list, so a bad view never silently hides everything.
struct CompiledFilter {
    let filter: Filter
    let field: FieldDefinition
    let optionOrder: [String]
    private(set) var day: DatePoint?

    init(_ filter: Filter, fields: [String: FieldDefinition]) throws {
        self.filter = filter
        field = try definition(filter.field, fields: fields)
        optionOrder = orderedOptions(field)
        guard FieldFilters.operators(for: field.type).contains(filter.op) else {
            throw FieldEngineError.unsupportedOperator(field.type, filter.op)
        }
        day = nil
        if [.isEmpty, .isNotEmpty, .thisWeek, .overdue].contains(filter.op) { return }
        let valid: Bool
        switch field.type {
        case .text, .url, .select, .multi:
            if case .string = filter.value { valid = true } else { valid = false }
        case .checkbox:
            if case .bool = filter.value { valid = true } else { valid = false }
        case .number: valid = decimal(filter.value) != nil
        case .date:
            if case .string(let string) = filter.value, let point = try? DatePoint(string), !point.isTimed {
                day = point
                return
            }
            valid = false
        default: valid = false
        }
        guard valid else { throw FieldEngineError.invalidFilterValue(filter.field) }
    }

    func matches(_ item: FieldItem, context: FieldContext) throws -> Bool {
        let cell = Cell.read(property(item, fieldID: filter.field), field: field, optionOrder: optionOrder)
        if filter.op == .isEmpty { return cell == nil }
        if filter.op == .isNotEmpty { return cell != nil }
        // Empty values never satisfy value comparisons, including negative operators.
        guard let cell else { return false }
        switch cell {
        case .text(let text):
            guard case .string(let operand) = filter.value else { return false }
            let a = folded(text), b = folded(operand)
            switch filter.op {
            case .contains: return a.contains(b)
            case .doesNotContain: return !a.contains(b)
            case .is: return a == b
            default: return false
            }
        case .number(let number):
            guard let operand = decimal(filter.value) else { return false }
            switch filter.op {
            case .eq: return number == operand
            case .ne: return number != operand
            case .lt: return number < operand
            case .le: return number <= operand
            case .gt: return number > operand
            case .ge: return number >= operand
            default: return false
            }
        case .checkbox(let checked):
            guard case .bool(let operand) = filter.value else { return false }
            return checked == operand
        case .options(let ids):
            guard case .string(let operand) = filter.value else { return false }
            return filter.op == .is ? ids.contains(operand) : !ids.contains(operand)
        case .files: return false // Emptiness operators return above.
        case .date(let date):
            let instant = date.start.isTimed
                ? try date.start.resolved(in: date.effectiveTimeZone(deviceTimeZone: context.timeZone)) : nil
            if filter.op == .overdue {
                if let instant { return instant < context.now }
                // Compare calendar labels directly: even a skipped local date stays date-only.
                return try date.start < DatePoint.from(context.now, in: context.timeZone, timed: false)
            }
            let localDay = try instant.map { try DatePoint.from($0, in: context.timeZone, timed: false) } ?? date.start
            if filter.op == .thisWeek {
                guard let week = context.calendar.dateInterval(of: .weekOfYear, for: context.now) else { return false }
                let first = try DatePoint.from(week.start, in: context.timeZone, timed: false)
                let last = try DatePoint.from(week.end, in: context.timeZone, timed: false)
                return localDay >= first && localDay < last
            }
            guard let operand = day else { return false }
            switch filter.op {
            case .before: return localDay < operand
            case .after: return localDay > operand
            case .on: return localDay == operand
            default: return false
            }
        }
    }
}
