import Foundation

/// The detail pane's cost in plain words. Every figure is an estimate and says so; a model without a price says that.
public struct ModelCostLine: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case ownUsage, relative, meter, unpriced }
    public var kind: Kind
    /// The line people read: "About $0.42 a turn for you", "About 5x the cost of Sonnet 5.5", "No price known".
    public var headline: String
    /// The meter's level, 1 to 4, when the headline is the meter.
    public var meter: Int?
    /// A second, smaller line: the API equivalent under a plan, or the per-1M prices.
    public var detail: String?
    /// Where the figure comes from, for the tooltip and VoiceOver.
    public var explanation: String

    /// How the provider is paid for.
    public enum Billing: Equatable, Sendable { case api, subscription(plan: String?) }

    public struct Input: Sendable {
        public var modelName: String
        public var price: ThreadCostEstimate.Price?
        /// True when the price came from models.dev, not CandyWrapper's own table.
        public var priceFromModelsDev = false
        /// This model's finished turns in USD at API prices, oldest first.
        public var ownTurns: [Double] = []
        public var reference: (name: String, price: ThreadCostEstimate.Price)?
        /// Every priced model in the picker, for the meter.
        public var catalogPrices: [ThreadCostEstimate.Price] = []
        public var billing: Billing = .api
        public init(modelName: String, price: ThreadCostEstimate.Price?, priceFromModelsDev: Bool = false, ownTurns: [Double] = [],
                    reference: (name: String, price: ThreadCostEstimate.Price)? = nil, catalogPrices: [ThreadCostEstimate.Price] = [],
                    billing: Billing = .api) {
            self.modelName = modelName; self.price = price; self.priceFromModelsDev = priceFromModelsDev; self.ownTurns = ownTurns
            self.reference = reference; self.catalogPrices = catalogPrices; self.billing = billing
        }
    }

    /// The fewest turns a median is shown from.
    static let minimumTurns = 5
    /// The median uses the latest this many turns.
    static let recentTurns = 40

    /// A typical coding turn, only for comparing models and placing them on the meter, never shown as dollars: 100K
    /// tokens in, 85K of them cache hits and 15K fresh, and 2K tokens out. Agent turns resend the conversation each
    /// request, so most input is cached; the mix sets how much output prices weigh against input prices.
    static func blended(_ p: ThreadCostEstimate.Price) -> Double {
        (15_000 * p.input + 85_000 * p.cachedInput + 2_000 * p.output) / 1_000_000
    }

    static func median(_ values: [Double]) -> Double {
        let s = values.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// "$0.42", "$1.20", "$12", "under $0.01".
    static func dollars(_ usd: Double) -> String {
        if usd < 0.01 { return "under $0.01" }
        if usd >= 10 { return "$\(Int(usd.rounded()))" }
        return String(format: "$%.2f", usd)
    }

    /// "About 5x the cost of X", "About a third of the cost of X", "About the same cost as X".
    static func relative(_ ratio: Double, to name: String) -> String {
        if ratio >= 0.85 && ratio <= 1.18 { return "About the same cost as \(name)" }
        if ratio > 1 {
            let n = ratio < 1.95 ? String(format: "%.1f", ratio) : String(Int(ratio.rounded()))
            return "About \(n)x the cost of \(name)"
        }
        let inverse = Int((1 / ratio).rounded())
        let words = [2: "half", 3: "a third", 4: "a quarter", 5: "a fifth", 6: "a sixth", 7: "a seventh", 8: "an eighth", 9: "a ninth", 10: "a tenth"]
        if let w = words[inverse] { return "About \(w) of the cost of \(name)" }
        return inverse > 10 ? "Under a tenth of the cost of \(name)" : "About \(String(format: "%.1f", ratio))x the cost of \(name)"
    }

    /// 1 to 4 by where the model's blended price falls among the picker's priced models.
    static func meter(_ price: ThreadCostEstimate.Price, among all: [ThreadCostEstimate.Price]) -> Int {
        // The catalog normally lists the model itself; count it once.
        let values = (all.contains(price) ? all : all + [price]).map(blended).sorted()
        let below = values.filter { $0 < blended(price) - 1e-12 }.count
        return min(4, 1 + Int(4 * Double(below) / Double(values.count)))
    }

    static func perMillion(_ p: ThreadCostEstimate.Price) -> String {
        func f(_ v: Double) -> String {
            v == v.rounded() ? "$\(Int(v))" : (v < 0.1 ? String(format: "$%.3f", v) : String(format: "$%.2f", v))
                .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
        }
        return "\(f(p.input)) in · \(f(p.output)) out per 1M tokens"
    }

    public static func make(_ input: Input) -> ModelCostLine {
        guard let price = input.price else {
            return ModelCostLine(kind: .unpriced, headline: "No price known", meter: nil, detail: nil,
                                 explanation: "Neither CandyWrapper's price table nor models.dev lists a price for \(input.modelName).")
        }
        let source = input.priceFromModelsDev ? "models.dev's price" : "CandyWrapper's price table"
        let turns = Array(input.ownTurns.suffix(recentTurns))
        let own = turns.count >= minimumTurns ? median(turns) : nil
        let ownText = own.map { _ in "Estimate: the median of your last \(turns.count) finished turns on \(input.modelName), priced at API rates." }
        let relative: (String, String)? = input.reference.map { ref in
            (Self.relative(blended(price) / blended(ref.price), to: ref.name),
             "Estimate from \(source), for a typical turn: 100K tokens in, most of them cached, and 2K out.")
        }
        let level = meter(price, among: input.catalogPrices)
        let meterText = "Estimate: \(level) of 4 among the priced models here, from \(source) for a typical turn."
        let prices = perMillion(price)

        if case .subscription(let plan) = input.billing {
            // CandyWrapper has no per-model rate for how fast a plan's limits run down, so the line compares models and
            // keeps dollars as the API equivalent.
            let planText = "\(plan ?? "Your plan") pays for these turns, so dollar figures are what the API would charge."
            if let (headline, why) = relative {
                return ModelCostLine(kind: .relative, headline: headline, meter: nil,
                                     detail: own.map { "About \(dollars($0)) a turn at API prices" } ?? prices,
                                     explanation: [why, ownText, planText].compactMap { $0 }.joined(separator: " "))
            }
            if let own, let ownText {
                return ModelCostLine(kind: .ownUsage, headline: "About \(dollars(own)) a turn at API prices", meter: nil, detail: prices,
                                     explanation: "\(ownText) \(planText)")
            }
            return ModelCostLine(kind: .meter, headline: "Cost", meter: level, detail: prices, explanation: "\(meterText) \(planText)")
        }
        if let own, let ownText {
            return ModelCostLine(kind: .ownUsage, headline: "About \(dollars(own)) a turn for you", meter: nil, detail: prices, explanation: ownText)
        }
        if let (headline, why) = relative {
            return ModelCostLine(kind: .relative, headline: headline, meter: nil, detail: prices, explanation: why)
        }
        return ModelCostLine(kind: .meter, headline: "Cost", meter: level, detail: prices, explanation: meterText)
    }

    /// What VoiceOver reads.
    public var accessibilityText: String {
        let main = meter.map { "Cost \($0) of 4" } ?? headline
        return [main, detail].compactMap { $0 }.joined(separator: ". ")
    }
}
