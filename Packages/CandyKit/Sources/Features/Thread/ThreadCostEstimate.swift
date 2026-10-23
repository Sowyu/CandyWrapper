import Foundation
import T3Protocol

/// What a thread would have cost at API prices, after Capy's tab bar figure; Redesign shows it in the thread header. Each provider turn reports its token
/// totals as `turnTokenUsage` when it ends (providerRuntime.ts:321-347, orchestrationV2.ts:989): input counts cache
/// reads and writes, output counts reasoning. A turn that ended without totals counts its latest request's
/// `tokenUsage` (orchestrationV2.ts:166-177). A running turn counts nothing until it ends: its `tokenUsage` is only
/// the latest request (ClaudeAdapterV2.ts:235-268, CodexAdapterV2.ts:194-206), so it would rise and fall.
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
        "claude-sonnet-5-5": Price(input: 2, cachedInput: 0.2, output: 10),
        "claude-fable-5": Price(input: 10, cachedInput: 1, output: 50),
        "claude-opus-5": Price(input: 5, cachedInput: 0.5, output: 25),
        "claude-sonnet-5": Price(input: 2, cachedInput: 0.2, output: 10),
        "claude-opus-4-8": Price(input: 5, cachedInput: 0.5, output: 25),
        "claude-opus-4-7": Price(input: 5, cachedInput: 0.5, output: 25),
        "claude-haiku-5-5": Price(input: 0.1, cachedInput: 0.01, output: 0.5),
        "claude-opus-4-6": Price(input: 5, cachedInput: 0.5, output: 25),
        "claude-sonnet-4-6": Price(input: 3, cachedInput: 0.3, output: 15),
        "claude-haiku-4-5": Price(input: 1, cachedInput: 0.1, output: 5),
        "claude-opus-4-5": Price(input: 5, cachedInput: 0.5, output: 25),
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

    /// The estimate split by kind of token, with the models it was priced as.
    public struct Breakdown: Equatable, Sendable {
        /// Summed over turns; `input` counts cache reads and writes.
        public var tokens = Tokens(input: 0, output: 0)
        public var inputUSD = 0.0, cachedUSD = 0.0, cacheWriteUSD = 0.0, outputUSD = 0.0
        /// In order of first use.
        public var models: [String] = []
        /// Every subagent thread under this one with usage, nested ones included, depth first.
        public var subagents: [Subagent] = []
        /// Subagent threads left out because their projection couldn't be read.
        public var subagentsUnread = 0
        /// Subagent threads left out because a turn ran on a model without a price.
        public var subagentsUnpriced = 0
        /// Models without a price, in order of first use: this thread's own in `own(_:)`, its subagents' in the tree.
        public var unpricedModels: [String] = []
        /// This thread's own turns.
        public var ownUSD: Double { inputUSD + cachedUSD + cacheWriteUSD + outputUSD }
        public var subagentsUSD: Double { subagents.reduce(0) { $0 + $1.usd } }
        public var usd: Double { ownUSD + subagentsUSD }
        public init() {}
        mutating func add(_ t: Tokens, _ p: Price, model: String) {
            tokens.input += t.input; tokens.cached += t.cached; tokens.cacheWrite += t.cacheWrite; tokens.output += t.output
            inputUSD += max(0, t.input - t.cached - t.cacheWrite) * p.input / 1_000_000
            cachedUSD += t.cached * p.cachedInput / 1_000_000
            cacheWriteUSD += t.cacheWrite * p.cacheWrite / 1_000_000
            outputUSD += t.output * p.output / 1_000_000
            if !models.contains(model) { models.append(model) }
        }
    }

    /// One subagent thread's own turns, priced by its own models.
    public struct Subagent: Equatable, Sendable {
        public var title: String, models: [String], tokens: Tokens, usd: Double
    }

    /// A subagent thread as the card reads it: `own` is its `own(_:)` breakdown, nil when its projection
    /// couldn't be read. `reading` marks one whose first read is still in flight.
    public struct SubagentThread: Sendable {
        public var id: ThreadId, title: String, own: Breakdown?, reading: Bool
        public init(id: ThreadId, title: String, own: Breakdown?, reading: Bool = false) {
            self.id = id; self.title = title; self.own = own; self.reading = reading
        }
    }

    /// The thread's estimate in USD, or nil when it has no usage or any turn ran on a model without a price.
    public static func usd(_ projection: ThreadProjection?) -> Double? { breakdown(projection)?.usd }

    /// The thread's estimate by kind of token, nil as `usd` is.
    public static func breakdown(_ projection: ThreadProjection?) -> Breakdown? {
        guard let projection else { return nil }
        let b = own(projection)
        guard b.unpricedModels.isEmpty, !b.models.isEmpty else { return nil }
        return b
    }

    /// The open thread's estimate with every subagent thread under it, each priced by its own models. Subagent
    /// turns count in their own threads only: T3 scopes a turn's totals to the main agent (providerRuntime.ts:321-331).
    /// Nil when the thread's own turns can't be priced, nothing has usage yet, or a subagent's first read is in flight,
    /// so the figure appears once with its subagents instead of jumping when they arrive.
    public static func breakdown(_ projection: ThreadProjection, id: ThreadId, children: (ThreadId) -> [SubagentThread]) -> Breakdown? {
        var result = own(projection)
        guard result.unpricedModels.isEmpty else { return nil }
        var seen: Set<ThreadId> = [id], reading = false
        func walk(_ parent: ThreadId) {
            for child in children(parent) where seen.insert(child.id).inserted {
                if let b = child.own, !b.unpricedModels.isEmpty {
                    result.subagentsUnpriced += 1
                    for m in b.unpricedModels where !result.unpricedModels.contains(m) { result.unpricedModels.append(m) }
                } else if let b = child.own {
                    if !b.models.isEmpty { result.subagents.append(Subagent(title: child.title, models: b.models, tokens: b.tokens, usd: b.ownUSD)) }
                } else if child.reading {
                    reading = true
                } else {
                    result.subagentsUnread += 1
                }
                walk(child.id)
            }
        }
        walk(id)
        if reading { return nil }
        return result.models.isEmpty && result.subagents.isEmpty ? nil : result
    }

    /// The thread's own turns, no models when it has none. Turns on a model without a price only add to `unpricedModels`.
    public static func own(_ projection: ThreadProjection) -> Breakdown {
        let runByAttempt = Dictionary(projection.attempts.map { ($0.id.rawValue, $0.runId) }, uniquingKeysWith: { a, _ in a })
        let modelByRun = Dictionary(projection.runs.compactMap { run in run.modelSelection.map { (run.id, $0.model) } }, uniquingKeysWith: { a, _ in a })
        let runByNode = Dictionary(projection.nodes.compactMap { node in node.runId.map { (node.id.rawValue, $0) } }, uniquingKeysWith: { a, _ in a })
        // A turn with no run of its own, like a Codex subagent's turn in its child thread (CodexAdapterV2.ts:2648-2656),
        // takes the latest run's model, else the thread's (orchestrationV2.ts:378).
        let fallback = projection.runs.max { $0.ordinal < $1.ordinal }?.modelSelection?.model
            ?? projection.thread.raw["modelSelection"]?["model"]?.stringValue
        var result = Breakdown()
        for turn in projection.providerTurns {
            guard let tokens = tokens(turn) else { continue }
            let run = turn["runAttemptId"]?.stringValue.flatMap { runByAttempt[$0] } ?? turn["nodeId"]?.stringValue.flatMap { runByNode[$0] }
            let model = run.flatMap { modelByRun[$0] } ?? fallback ?? "an unknown model"
            guard let price = price(model) else {
                if !result.unpricedModels.contains(model) { result.unpricedModels.append(model) }
                continue
            }
            result.add(tokens, price, model: model)
        }
        return result
    }

    /// A turn's totals, else its latest request once it has ended. Nil while it runs.
    static func tokens(_ turn: JSONValue) -> Tokens? {
        if let usage = turn["turnTokenUsage"], let input = usage["inputTokens"]?.doubleValue, let output = usage["outputTokens"]?.doubleValue {
            return Tokens(input: input, cached: usage["cachedInputTokens"]?.doubleValue ?? 0,
                          cacheWrite: usage["cacheCreationTokens"]?.doubleValue ?? 0, output: output)
        }
        let status = turn["status"]?.stringValue
        guard status != "running", status != "pending", let usage = turn["tokenUsage"],
              let input = usage["inputTokens"]?.doubleValue, let output = usage["outputTokens"]?.doubleValue else { return nil }
        return Tokens(input: input, cached: usage["cachedInputTokens"]?.doubleValue ?? 0, output: output)
    }

    /// "$0.00", as Capy's tab bar shows it.
    public static func label(_ usd: Double) -> String { String(format: "$%.2f", usd) }
}
