import Foundation
import SpaceModel

public enum FieldEngineError: Error, Equatable, Sendable {
    case unknownField(String)
    case unsupportedType(FieldType)
    case unsupportedOperator(FieldType, FilterOp)
    case invalidFilterValue(String)
    case tooManySorts
    case cannotGroup(FieldType)
    case reservedField(String)
}

/// The caller supplies the clock and device zone once per query. No global clock or locale is read.
public struct FieldContext: Sendable {
    public var now: Date
    public var timeZone: TimeZone

    public init(now: Date, timeZone: TimeZone) {
        self.now = now
        self.timeZone = timeZone
    }

    var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = timeZone
        result.firstWeekday = 2
        result.minimumDaysInFirstWeek = 4
        return result
    }
}

public struct FieldItem: Equatable, Sendable {
    public var id: PageID
    public var page: PageRecord

    public init(id: PageID, page: PageRecord) {
        self.id = id
        self.page = page
    }
}

// A schema mismatch behaves like an empty cell in queries. Conversion still reports its loss.
enum Cell: Equatable {
    case text(String), number(Decimal), checkbox(Bool), options([String]), date(DateValue)

    static func read(_ value: PropertyValue?, field: FieldDefinition, optionOrder: [String]? = nil) -> Self? {
        switch (field.type, value) {
        case (.text, .string(let text)), (.url, .string(let text)):
            return text.isEmpty ? nil : .text(text)
        case (.number, .number(let number)):
            return number.isNaN ? nil : .number(number)
        case (.checkbox, .checkbox(let checked)):
            return .checkbox(checked)
        case (.select, .string(let id)):
            return field.options?[id] == nil ? nil : .options([id])
        case (.multi, .multi(let ids)):
            let selected = (optionOrder ?? orderedOptions(field)).filter { ids.contains($0) }
            return selected.isEmpty ? nil : .options(selected)
        case (.date, .date(let date)):
            guard (try? date.validate()) != nil else { return nil }
            return .date(date)
        default: return nil
        }
    }
}

func orderedOptions(_ field: FieldDefinition) -> [String] {
    let options = field.options ?? [:]
    return options.keys.sorted {
        if options[$0]!.order != options[$1]!.order { return options[$0]!.order < options[$1]!.order }
        return byteLess($0, $1)
    }
}

func byteLess(_ lhs: String, _ rhs: String) -> Bool {
    lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
}

// Fixed Unicode case folding, independent of the Mac's language and collation preferences.
func folded(_ text: String) -> String {
    text.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX")).precomposedStringWithCanonicalMapping
}

func definition(_ id: String, fields: [String: FieldDefinition]) throws -> FieldDefinition {
    if id == FieldID.title {
        return FieldDefinition(name: "Title", type: .text, order: try OrderKey("a0"))
    }
    guard let field = fields[id] else { throw FieldEngineError.unknownField(id) }
    guard FieldType.allCases.contains(field.type) else { throw FieldEngineError.unsupportedType(field.type) }
    return field
}

func property(_ item: FieldItem, fieldID: String) -> PropertyValue? {
    fieldID == FieldID.title ? .string(item.page.title) : item.page.props[fieldID]
}

func decimal(_ json: JSONValue) -> Decimal? {
    switch json {
    case .integer(let value): return Decimal(value)
    case .unsigned(let value): return Decimal(value)
    case .number(let value): return value.isNaN ? nil : value
    default: return nil
    }
}

func parseNumber(_ text: String) -> Decimal? {
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard value.range(of: "^[+-]?(?:[0-9]+(?:\\.[0-9]*)?|\\.[0-9]+)(?:[eE][+-]?[0-9]+)?$", options: .regularExpression) != nil,
          let number = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")), !number.isNaN,
          decimalParts(value) == decimalParts(NSDecimalNumber(decimal: number).stringValue) else { return nil }
    return number
}

// Compare significands and exponents without expanding large exponents or going through Double.
private func decimalParts(_ text: String) -> String? {
    var value = text.lowercased()
    let negative = value.hasPrefix("-")
    if value.hasPrefix("-") || value.hasPrefix("+") { value.removeFirst() }
    let parts = value.split(separator: "e", omittingEmptySubsequences: false)
    guard parts.count <= 2, let exponent = parts.count == 2 ? Int(parts[1]) : 0 else { return nil }
    let decimal = parts[0].split(separator: ".", omittingEmptySubsequences: false)
    let fraction = decimal.count == 2 ? decimal[1].count : 0
    var digits = decimal.joined()
    while digits.first == "0" { digits.removeFirst() }
    if digits.isEmpty { return "0" }
    var trailing = 0
    while digits.last == "0" { digits.removeLast(); trailing += 1 }
    let (scale, underflow) = exponent.subtractingReportingOverflow(fraction)
    let (normalized, overflow) = scale.addingReportingOverflow(trailing)
    guard !underflow, !overflow else { return nil }
    return "\(negative ? "-" : "")\(digits)e\(normalized)"
}
