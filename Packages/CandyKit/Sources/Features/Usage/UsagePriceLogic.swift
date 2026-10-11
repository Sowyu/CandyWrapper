import Foundation
import T3Protocol

/// `UsageModelPriceOverride` (contracts settings.ts:520-525): USD per million tokens.
public struct UsageModelPrice: Equatable, Sendable {
    public var input: Double
    public var output: Double
    public var cacheRead: Double?
    public var cacheWrite: Double?
    public init(input: Double, output: Double, cacheRead: Double? = nil, cacheWrite: Double? = nil) {
        self.input = input; self.output = output; self.cacheRead = cacheRead; self.cacheWrite = cacheWrite
    }
    init?(json: JSONValue) {
        guard let i = json["inputCostPerMillionTokens"]?.doubleValue, let o = json["outputCostPerMillionTokens"]?.doubleValue else { return nil }
        self.init(input: i, output: o, cacheRead: json["cacheReadCostPerMillionTokens"]?.doubleValue,
                  cacheWrite: json["cacheWriteCostPerMillionTokens"]?.doubleValue)
    }
    public var json: JSONValue {
        var o: [String: JSONValue] = ["inputCostPerMillionTokens": .number(input), "outputCostPerMillionTokens": .number(output)]
        if let cacheRead { o["cacheReadCostPerMillionTokens"] = .number(cacheRead) }
        if let cacheWrite { o["cacheWriteCostPerMillionTokens"] = .number(cacheWrite) }
        return .object(o)
    }
}

/// One environment the price table writes to (`UsagePriceTarget`, usagePriceTargets.ts:7-14).
public struct UsagePriceTarget: Equatable, Sendable {
    public var environmentId: String
    public var label: String
    /// Nil when not loaded.
    public var prices: [String: UsageModelPrice]?
    /// Nil when not loaded or the server cannot store mappings.
    public var aliases: [String: String]?
    public var unavailable: String?
    public init(environmentId: String, label: String, prices: [String: UsageModelPrice]?, aliases: [String: String]?, unavailable: String?) {
        self.environmentId = environmentId; self.label = label; self.prices = prices; self.aliases = aliases; self.unavailable = unavailable
    }

    /// From an environment's settings (`usagePriceOverrides`, `usageModelAliases`) and capabilities, as `priceTargetsAtom` does.
    public static func make(environmentId: String, label: String, connected: Bool, settings: JSONValue?, capabilities: Set<String>,
                            canWrite: Bool) -> UsagePriceTarget {
        let prices = settings.map { s in (s["usagePriceOverrides"]?.objectValue ?? [:]).compactMapValues(UsageModelPrice.init(json:)) }
        let aliases = capabilities.contains("usageModelAliases")
            ? settings.map { s in (s["usageModelAliases"]?.objectValue ?? [:]).compactMapValues(\.stringValue) } : nil
        let unavailable: String? = !connected ? "Offline"
            : settings == nil ? "Prices not loaded"
            : !capabilities.contains("usagePriceOverrides") ? "Update server to edit prices"
            : !canWrite ? "Read-only access" : nil
        return UsagePriceTarget(environmentId: environmentId, label: label, prices: prices, aliases: aliases, unavailable: unavailable)
    }
}

/// One row of the table (`UsagePriceDraft`, usagePriceTable.ts:11-19).
public struct UsagePriceDraft: Equatable, Sendable {
    public var id: String
    public var model: String
    public var isNew: Bool
    /// Edited cells by field; absent fields keep each environment's rate.
    public var values: [UsagePriceLogic.Field: String] = [:]
    /// Edited "Map to"; nil keeps each environment's mapping, blank removes it.
    public var alias: String?
    public var removed = false
    public init(id: String, model: String, isNew: Bool, values: [UsagePriceLogic.Field: String] = [:], alias: String? = nil, removed: Bool = false) {
        self.id = id; self.model = model; self.isNew = isNew; self.values = values; self.alias = alias; self.removed = removed
    }

    /// `isEmptyUsagePriceDraft`.
    public var isEmpty: Bool {
        isNew && model.trimmingCharacters(in: .whitespaces).isEmpty && (alias ?? "").trimmingCharacters(in: .whitespaces).isEmpty
            && values.values.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}

/// A change for one model on one environment: a price (nil restores automatic) or a mapping (nil removes it).
public enum UsagePriceChange: Equatable, Sendable {
    case price(model: String, UsageModelPrice?)
    case alias(model: String, String?)
}

/// The price table's rules (usagePriceForm.ts, usagePriceTable.ts, usagePriceTargets.ts).
public enum UsagePriceLogic {
    public enum Field: String, CaseIterable, Sendable {
        case input = "inputCostPerMillionTokens", output = "outputCostPerMillionTokens"
        case cacheRead = "cacheReadCostPerMillionTokens", cacheWrite = "cacheWriteCostPerMillionTokens"
        public var label: String {
            switch self {
            case .input: "Input"
            case .output: "Output"
            case .cacheRead: "Cache read"
            case .cacheWrite: "Cache write"
            }
        }
        public var optional: Bool { self == .cacheRead || self == .cacheWrite }
    }

    /// JS `Number.prototype.toString` for a rate.
    static func numberString(_ v: Double) -> String { v == v.rounded() && abs(v) < 1e15 ? String(Int(v)) : String(v) }

    /// `usagePriceForm`: the saved rates as text, blank when unset.
    public static func form(_ price: UsageModelPrice?) -> [Field: String] {
        [.input: price.map { numberString($0.input) } ?? "", .output: price.map { numberString($0.output) } ?? "",
         .cacheRead: price?.cacheRead.map(numberString) ?? "", .cacheWrite: price?.cacheWrite.map(numberString) ?? ""]
    }

    /// `parseUsagePriceForm`: blank cache rates use the input rate; explicit zero is free.
    public static func parse(model: String, _ form: [Field: String]) -> (model: String, price: UsageModelPrice)? {
        let m = model.trimmingCharacters(in: .whitespaces)
        guard !m.isEmpty else { return nil }
        var rates: [Field: Double] = [:]
        for field in Field.allCases {
            let raw = (form[field] ?? "").trimmingCharacters(in: .whitespaces)
            if raw.isEmpty {
                if field.optional { continue }
                return nil
            }
            guard raw.wholeMatch(of: /(?i)(?:\d+(?:\.\d*)?|\.\d+)(?:e[+-]?\d+)?/) != nil, let v = Double(raw), v.isFinite, v >= 0 else { return nil }
            rates[field] = v
        }
        guard let i = rates[.input], let o = rates[.output] else { return nil }
        return (m, UsageModelPrice(input: i, output: o, cacheRead: rates[.cacheRead], cacheWrite: rates[.cacheWrite]))
    }

    /// A cell's shown value and placeholder: `Mixed`, `Unavailable`, `Automatic`, `Input rate` or `0.00`.
    public struct Cell: Equatable, Sendable {
        public var value: String
        public var placeholder: String
    }

    /// `usageAliasCell`.
    public static func aliasCell(_ targets: [UsagePriceTarget], model: String) -> Cell {
        if targets.contains(where: { $0.aliases == nil }) { return Cell(value: "", placeholder: "Unavailable") }
        let values = targets.map { $0.aliases?[model] ?? "" }
        if values.contains(where: { $0 != values.first }) { return Cell(value: "", placeholder: "Mixed") }
        return Cell(value: values.first ?? "", placeholder: "None")
    }

    /// `usagePriceCell`.
    public static func priceCell(_ targets: [UsagePriceTarget], model: String, field: Field) -> Cell {
        let values: [String?] = targets.map { t in t.prices?[model].map { form($0)[field] ?? "" } }
        if targets.contains(where: { $0.prices == nil }) { return Cell(value: "", placeholder: "Unavailable") }
        if values.contains(where: { $0 != values.first }) { return Cell(value: "", placeholder: "Mixed") }
        let first = values.first ?? nil
        return Cell(value: first ?? "", placeholder: first == nil ? "Automatic" : field.optional ? "Input rate" : "0.00")
    }

    /// `usagePriceTableChanges`: only edited cells replace rates.
    public static func changes(_ target: UsagePriceTarget, _ drafts: [UsagePriceDraft]) -> (changes: [UsagePriceChange], errors: [String: String]) {
        var changes: [UsagePriceChange] = []
        var errors: [String: String] = [:]
        for draft in drafts where !draft.isEmpty {
            let model = draft.model.trimmingCharacters(in: .whitespaces)
            let currentAlias = target.aliases?[model]
            let currentPrice = target.prices?[model]
            if draft.removed {
                if currentPrice != nil { changes.append(.price(model: model, nil)) }
                if currentAlias != nil { changes.append(.alias(model: model, nil)) }
                continue
            }
            let alias = (draft.alias ?? currentAlias ?? "").trimmingCharacters(in: .whitespaces)
            if !alias.isEmpty {
                if model.isEmpty { errors[draft.id] = "Enter a model ID." }
                else if alias == model { errors[draft.id] = "Map to a different model." }
                else {
                    if alias != currentAlias { changes.append(.alias(model: model, alias)) }
                    if currentPrice != nil { changes.append(.price(model: model, nil)) }
                }
                continue
            }
            if currentAlias != nil {
                changes.append(.alias(model: model, nil))
                if currentPrice == nil, draft.values.values.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) { continue }
            }
            let original = form(currentPrice)
            let merged = original.merging(draft.values) { _, new in new }
            guard let parsed = parse(model: model, merged) else {
                let missing = Field.allCases.first { !$0.optional && (merged[$0] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
                errors[draft.id] = model.isEmpty ? "Enter a model ID."
                    : missing.map { "\($0.label) is required on \(target.label)." } ?? "Use non-negative numbers for prices."
                continue
            }
            let next = form(parsed.price)
            if Field.allCases.contains(where: { original[$0] != next[$0] }) { changes.append(.price(model: parsed.model, parsed.price)) }
        }
        return (changes, errors)
    }

    /// `usagePriceTableErrors`: errors from writable destinations only.
    public static func errors(_ targets: [UsagePriceTarget], _ drafts: [UsagePriceDraft]) -> [String: String] {
        var out: [String: String] = [:]
        for t in targets where t.unavailable == nil && t.prices != nil {
            for (k, v) in changes(t, drafts).errors { out[k] = v }
        }
        return out
    }

    /// The `server.updateSettings` patch for one destination (`writeUsagePrices`): prices and mappings in one write.
    public static func patch(_ changes: [UsagePriceChange]) -> [String: JSONValue] {
        var prices: [String: JSONValue] = [:], aliases: [String: JSONValue] = [:]
        for c in changes {
            switch c {
            case .price(let model, let price): prices[model] = price?.json ?? .null
            case .alias(let model, let alias): aliases[model] = alias.map(JSONValue.string) ?? .null
            }
        }
        var patch: [String: JSONValue] = [:]
        if !prices.isEmpty { patch["usagePriceOverrides"] = .object(prices) }
        if !aliases.isEmpty { patch["usageModelAliases"] = .object(aliases) }
        return patch
    }

    /// Why a destination cannot take the write before it is attempted, or nil.
    public static func blocker(_ target: UsagePriceTarget, _ changes: [UsagePriceChange]) -> String? {
        if let u = target.unavailable { return u }
        if changes.contains(where: { if case .alias = $0 { true } else { false } }), target.aliases == nil { return "Update server to map models" }
        return nil
    }
}
