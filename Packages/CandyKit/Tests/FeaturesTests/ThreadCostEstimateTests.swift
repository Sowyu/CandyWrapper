import Foundation
import Testing
import T3Protocol
@testable import Features

/// Redesign's header cost estimate: API prices per million tokens over each provider turn's totals.
@Suite struct ThreadCostEstimateTests {
    @Test func pricesSplitInputIntoUncachedCachedAndWritten() throws {
        let opus = try #require(ThreadCostEstimate.price("claude-opus-5-5"))
        // 1M input of which 600k cache reads and 100k writes, plus 50k output.
        let tokens = ThreadCostEstimate.Tokens(input: 1_000_000, cached: 600_000, cacheWrite: 100_000, output: 50_000)
        // 300k at $4, 600k at $0.20, 100k at $5 and 50k at $20.
        #expect(abs(tokens.cost(opus) - (1.2 + 0.12 + 0.5 + 1.0)) < 1e-9)
        #expect(ThreadCostEstimate.label(2.8249) == "$2.82")
        #expect(ThreadCostEstimate.label(0.001) == "$0.00")
    }

    @Test func theBreakdownSplitsTheSameTotalByKind() throws {
        let opus = try #require(ThreadCostEstimate.price("claude-opus-5-5"))
        let tokens = ThreadCostEstimate.Tokens(input: 1_000_000, cached: 600_000, cacheWrite: 100_000, output: 50_000)
        var b = ThreadCostEstimate.Breakdown()
        b.add(tokens, opus, model: "claude-opus-5-5")
        b.add(tokens, opus, model: "claude-opus-5-5")
        #expect(abs(b.inputUSD - 2.4) < 1e-9 && abs(b.cachedUSD - 0.24) < 1e-9 && abs(b.cacheWriteUSD - 1) < 1e-9 && abs(b.outputUSD - 2) < 1e-9)
        #expect(abs(b.usd - 2 * tokens.cost(opus)) < 1e-9)
        #expect(b.models == ["claude-opus-5-5"] && b.tokens.input == 2_000_000)
    }

    @Test func modelNamesIgnoreContextTagsAndDatesAndUnknownModelsHaveNoPrice() {
        #expect(ThreadCostEstimate.price("claude-opus-5-5[1m]") == ThreadCostEstimate.price("claude-opus-5-5"))
        #expect(ThreadCostEstimate.price("claude-haiku-4-5-20251001") != nil)
        #expect(ThreadCostEstimate.price("gpt-6.1-sol") != nil)
        #expect(ThreadCostEstimate.price("muse-spark-1.3") == nil)
    }

    @Test func aTurnUsesItsTotalsElseItsLatestRequest() throws {
        let done = try JSONDecoder().decode(JSONValue.self, from: Data("""
        {"status":"completed","tokenUsage":{"inputTokens":9,"outputTokens":9,"usedTokens":18},
         "turnTokenUsage":{"usageScope":"main_agent","usageStatus":"complete","hasSubagents":false,
                           "inputTokens":1000,"cachedInputTokens":400,"cacheCreationTokens":100,"outputTokens":50}}
        """.utf8))
        #expect(ThreadCostEstimate.tokens(done) == .init(input: 1000, cached: 400, cacheWrite: 100, output: 50))
        let running = try JSONDecoder().decode(JSONValue.self, from: Data("""
        {"status":"running","tokenUsage":{"inputTokens":700,"cachedInputTokens":200,"outputTokens":30,"usedTokens":730}}
        """.utf8))
        #expect(ThreadCostEstimate.tokens(running) == .init(input: 700, cached: 200, output: 30))
        let empty = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"status":"pending"}"#.utf8))
        #expect(ThreadCostEstimate.tokens(empty) == nil)
    }
}
