import Foundation
import T3Protocol

/// What a thread would have cost at API prices, after Capy's tab bar figure. Each provider turn reports its token
/// totals as `turnTokenUsage` when it ends (providerRuntime.ts:321-347, orchestrationV2.ts:989): input counts cache
/// reads and writes, output counts reasoning. A turn without totals, such as one still running, counts its latest
/// request's `tokenUsage` (orchestrationV2.ts:166-177).
public enum ThreadCostEstimate {
    /// USD per million tokens.
    public struct Price: Equatable, Sendable {
        public var input: Double, cachedInput: Double, cacheWrite: Double, output: Double
        public init(input: Double, cachedInput: Double, cacheWrite: Double? = nil, output: Double) {
            self.input = input; self.cachedInput = cachedInput; self.cacheWrite = cacheWrite ?? input * 1.25; self.output = output
        }
    }

    // ponytail: a fixed table of the Claude and GPT models in use on 2026-10-22, from LiteLLM's
    // model_prices_and_context_window.json (the list T3's usage page prices from); unknown models hide the figure.
    // Read the server's price table (usagePricing.ts) once the wire exposes it, or when prices change.
    static let prices: [String: Price] = [
        "claude-fable-5-1": Price(input: 10, cachedInput: 0.25, output: 50),
        "claude-opus-5-5": Price(input: 4, cachedInput: 0.2, output: 20),
        "claude-sonnet-5-5": Price(input: 2, cachedInput: 0.1, output: 10),
        "claude-haiku-5-5": Price(input: 0.1, cachedInput: 0.01, output: 0.5),
        "claude-opus-4-6": Price(input: 5, cachedInput: 0.5, output: 25),
        "claude-sonnet-4-6": Price(input: 3, cachedInput: 0.3, output: 15),
        "claude-haiku-4-5": Price(input: 1, cachedInput: 0.1, output: 5),
        "gpt-6-astra": Price(input: 10, cachedInput: 1, output: 50),
        "gpt-6.1-sol": Price(input: 2, cachedInput: 0.1, output: 10),
        "gpt-6-sol": Price(input: 2, cachedInput: 0.2, output: 10),
        "gpt-6-luna": Price(input: 0.1, cachedInput: 0.01, output: 0.5),
        "gpt-5.6-sol": Price(input: 4, cachedInput: 0.4, output: 20),
        "gpt-5.6-terra": Price(input: 2, cachedInput: 0.2, output: 12),
        "gpt-5.6-luna": Price(input: 0.2, cachedInput: 0.02, output: 1.2),
    ]

    /// The price of `model`, ignoring a `[1m]` context tag and a date suffix such as `-20251001`.
    public static func price(_ model: String) -> Price? {
        var key = model.lowercased()
        if let bracket = key.firstIndex(of: "[") { key = String(key[..<bracket]) }
        key = key.replacingOccurrences(of: #"-\d{8}$"#, with: "", options: .regularExpression)
        return prices[key]
    }

    public struct Tokens: Equatable, Sendable {
        /// All input, cache reads and writes included.
        public var input: Double, cached: Double, cacheWrite: Double, output: Double
        public init(input: Double, cached: Double = 0, cacheWrite: Double = 0, output: Double) {
            self.input = input; self.cached = cached; self.cacheWrite = cacheWrite; self.output = output
        }
        public func cost(_ p: Price) -> Double {
            let uncached = max(0, input - cached - cacheWrite)
            return (uncached * p.input + cached * p.cachedInput + cacheWrite * p.cacheWrite + output * p.output) / 1_000_000
        }
    }

    /// The thread's estimate in USD, or nil when it has no usage or any turn ran on a model without a price.
    public static func usd(_ projection: ThreadProjection?) -> Double? {
        guard let projection else { return nil }
        let runByAttempt = Dictionary(projection.attempts.map { ($0.id.rawValue, $0.runId) }, uniquingKeysWith: { a, _ in a })
        let modelByRun = Dictionary(projection.runs.compactMap { run in run.modelSelection.map { (run.id, $0.model) } }, uniquingKeysWith: { a, _ in a })
        let fallback = projection.runs.max { $0.ordinal < $1.ordinal }?.modelSelection?.model
        var total = 0.0, counted = false
        for turn in projection.providerTurns {
            guard let tokens = tokens(turn) else { continue }
            let run = turn["runAttemptId"]?.stringValue.flatMap { runByAttempt[$0] }
            guard let model = run.flatMap({ modelByRun[$0] }) ?? fallback, let price = price(model) else { return nil }
            total += tokens.cost(price)
            counted = true
        }
        return counted ? total : nil
    }

    /// A turn's totals, else its latest request.
    static func tokens(_ turn: JSONValue) -> Tokens? {
        if let usage = turn["turnTokenUsage"], let input = usage["inputTokens"]?.doubleValue, let output = usage["outputTokens"]?.doubleValue {
            return Tokens(input: input, cached: usage["cachedInputTokens"]?.doubleValue ?? 0,
                          cacheWrite: usage["cacheCreationTokens"]?.doubleValue ?? 0, output: output)
        }
        guard let usage = turn["tokenUsage"],
              let input = usage["inputTokens"]?.doubleValue, let output = usage["outputTokens"]?.doubleValue else { return nil }
        return Tokens(input: input, cached: usage["cachedInputTokens"]?.doubleValue ?? 0, output: output)
    }

    /// "$0.00", as Capy's tab bar shows it.
    public static func label(_ usd: Double) -> String { String(format: "$%.2f", usd) }
}
