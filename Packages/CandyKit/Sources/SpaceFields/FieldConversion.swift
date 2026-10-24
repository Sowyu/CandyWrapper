import Foundation
import SpaceModel

public enum ConversionOutcome: Equatable, Sendable {
    case empty, kept, converted, partial, cleared
}

public struct PropertyConversion: Equatable, Sendable {
    /// Nil means remove the prop. The original records are never changed by a preview.
    public let value: PropertyValue?
    public let outcome: ConversionOutcome
    public var losesInformation: Bool { outcome == .partial || outcome == .cleared }
}

public struct ItemConversion: Equatable, Sendable {
    public let id: PageID
    public let result: PropertyConversion
}

public struct FieldConversionPlan: Equatable, Sendable {
    public let fieldID: String
    public let target: FieldDefinition
    public let items: [ItemConversion]
    /// Count affected item values, including partial multi-select and date metadata losses.
    public var lostValueCount: Int { items.filter { $0.result.losesInformation }.count }
    public var clearedValueCount: Int { items.filter { $0.result.outcome == .cleared }.count }
}

public enum FieldConversion {
    public static func preview(_ items: [FieldItem], fieldID: String, source: FieldDefinition,
                               target: FieldDefinition, context: FieldContext) throws -> FieldConversionPlan {
        // Title is a page key, and Done and Due have fixed schema types on every client.
        guard fieldID != FieldID.title,
              fieldID != FieldID.done || target.type == .checkbox,
              fieldID != FieldID.due || target.type == .date else { throw FieldEngineError.reservedField(fieldID) }
        // Validate even when no items exist.
        try validate(source, target)
        let results = try items.map { item in
            ItemConversion(id: item.id, result: try convert(item.page.props[fieldID], from: source,
                                                          to: target, context: context))
        }
        return FieldConversionPlan(fieldID: fieldID, target: target, items: results)
    }

    public static func convert(_ value: PropertyValue?, from source: FieldDefinition,
                               to target: FieldDefinition, context: FieldContext) throws -> PropertyConversion {
        try validate(source, target)
        // A no-op preserves unfamiliar values and metadata verbatim.
        if source.type == target.type && (![.select, .multi].contains(source.type) || source.options == target.options) {
            return PropertyConversion(value: value, outcome: isEmpty(value) ? .empty : .kept)
        }
        guard !isEmpty(value) else { return PropertyConversion(value: nil, outcome: .empty) }
        guard let cell = Cell.read(value, field: source) else { return cleared }

        var loss = false
        let strings: [String]
        switch cell {
        case .text(let text): strings = [text]
        case .number(let number): strings = [NSDecimalNumber(decimal: number).stringValue]
        case .checkbox(let checked): strings = [checked ? "true" : "false"]
        case .options(let ids):
            strings = ids.map { source.options![$0]!.name }
            if case .multi(let original) = value { loss = !Set(original).isSubset(of: Set(ids)) }
        case .date(let date):
            strings = [date.start.rawValue]
            loss = date.end != nil || date.tz != nil || date.repeat != nil || date.remind != nil || !date.extra.isEmpty
        }
        let single = strings.count == 1 ? strings[0].trimmingCharacters(in: .whitespacesAndNewlines) : nil
        let converted: PropertyValue?
        switch target.type {
        case .text:
            converted = .string(strings.joined(separator: ", "))
        case .url:
            if let single, isURL(single) { converted = .string(single) } else { converted = nil }
        case .number:
            if case .checkbox(let checked) = cell { converted = .number(checked ? 1 : 0) }
            else { converted = single.flatMap(parseNumber).map(PropertyValue.number) }
        case .checkbox:
            if case .number(let number) = cell, number == 0 || number == 1 {
                converted = .checkbox(number == 1)
            } else if let single, ["true", "false"].contains(folded(single)) {
                converted = .checkbox(folded(single) == "true")
            } else { converted = nil }
        case .date:
            if let single, let point = try? DatePoint(single) {
                converted = .date(try DateValue(start: point, tz: point.isTimed ? context.timeZone.identifier : nil))
            } else { converted = nil }
        case .select, .multi:
            let targetIDs = orderedOptions(target)
            let sourceIDs: [String]
            if case .options(let ids) = cell { sourceIDs = ids } else { sourceIDs = [] }
            let matches = strings.enumerated().compactMap { index, name -> String? in
                // Keep identity through option renames when the target retains that id.
                if index < sourceIDs.count, target.options?[sourceIDs[index]] != nil { return sourceIDs[index] }
                let match = folded(name.trimmingCharacters(in: .whitespacesAndNewlines))
                return targetIDs.first { folded(target.options![$0]!.name.trimmingCharacters(in: .whitespacesAndNewlines)) == match }
            }
            let unique = targetIDs.filter { matches.contains($0) }
            loss = loss || matches.count < strings.count || Set(matches).count < matches.count
            if target.type == .select {
                loss = loss || unique.count > 1
                // Source option order decides which value survives a multi-to-select conversion.
                converted = matches.first.map(PropertyValue.string)
            } else { converted = unique.isEmpty ? nil : .multi(unique) }
        default: converted = nil // validate rejects unknown types above.
        }
        guard let converted, converted != .string("") else { return cleared }
        return PropertyConversion(value: converted, outcome: loss ? .partial : .converted)
    }

    private static let cleared = PropertyConversion(value: nil, outcome: .cleared)

    private static func validate(_ source: FieldDefinition, _ target: FieldDefinition) throws {
        for field in [source, target] where !FieldType.allCases.contains(field.type) {
            throw FieldEngineError.unsupportedType(field.type)
        }
    }

    private static func isEmpty(_ value: PropertyValue?) -> Bool {
        switch value {
        case nil, .unknown(.null), .string(""), .multi([]): return true
        default: return false
        }
    }

    private static func isURL(_ string: String) -> Bool {
        guard string.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let components = URLComponents(string: string), let scheme = components.scheme, !scheme.isEmpty else { return false }
        if ["http", "https"].contains(scheme.lowercased()) { return !(components.host ?? "").isEmpty }
        return !string.dropFirst(scheme.count + 1).isEmpty
    }
}
