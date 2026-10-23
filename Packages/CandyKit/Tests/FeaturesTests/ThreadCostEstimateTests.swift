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
        // A running turn's `tokenUsage` is its latest request alone, so it counts nothing until the turn ends.
        #expect(ThreadCostEstimate.tokens(running) == nil)
        let ended = try JSONDecoder().decode(JSONValue.self, from: Data("""
        {"status":"interrupted","tokenUsage":{"inputTokens":700,"cachedInputTokens":200,"outputTokens":30,"usedTokens":730}}
        """.utf8))
        #expect(ThreadCostEstimate.tokens(ended) == .init(input: 700, cached: 200, output: 30))
        let empty = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"status":"pending"}"#.utf8))
        #expect(ThreadCostEstimate.tokens(empty) == nil)
    }

    /// A projection whose every turn ran on `model`, one turn of `input` and `output` tokens.
    private func thread(_ model: String, input: Double, output: Double) throws -> ThreadProjection {
        var p = try #require(try ThreadPreview.projection(titled: ThreadPreview.commandsThread))
        for i in p.runs.indices { p.runs[i].modelSelection = ModelSelection(instanceId: "claudeAgent", model: model) }
        p.providerTurns = [.object(["turnTokenUsage": .object(["inputTokens": .number(input), "outputTokens": .number(output)])])]
        return p
    }

    @Test func subagentThreadsAddTheirOwnCostNestedOnesIncluded() throws {
        let root = ThreadId("env:root"), a = ThreadId("env:a"), b = ThreadId("env:b"), c = ThreadId("env:c"), d = ThreadId("env:d")
        let haiku = ThreadCostEstimate.own(try thread("claude-haiku-5-5", input: 1_000_000, output: 100_000))
        let sonnet = ThreadCostEstimate.own(try thread("claude-sonnet-5-5", input: 1_000_000, output: 0))
        let unpriced = ThreadCostEstimate.own(try thread("muse-spark-1.3", input: 10, output: 10))
        #expect(unpriced.unpricedModels == ["muse-spark-1.3"] && unpriced.models.isEmpty)
        // a (haiku) runs b (sonnet), which runs c (unread); d priced on an unknown model; b also lists the root, a cycle.
        let tree: [ThreadId: [ThreadCostEstimate.SubagentThread]] = [
            root: [.init(id: a, title: "A", own: haiku), .init(id: d, title: "D", own: unpriced)],
            a: [.init(id: b, title: "B", own: sonnet)],
            b: [.init(id: c, title: "C", own: nil), .init(id: root, title: "Root", own: haiku)],
        ]
        let result = try #require(ThreadCostEstimate.breakdown(try thread("claude-opus-5-5", input: 1_000_000, output: 0), id: root) { tree[$0] ?? [] })
        // Opus $4, haiku $0.10 + $0.05, sonnet $2.
        #expect(abs(result.ownUSD - 4) < 1e-9)
        #expect(result.subagents.map(\.title) == ["A", "B"])
        #expect(result.subagents.map(\.models) == [["claude-haiku-5-5"], ["claude-sonnet-5-5"]])
        #expect(abs(result.subagentsUSD - 2.15) < 1e-9 && abs(result.usd - 6.15) < 1e-9)
        #expect(result.subagentsUnread == 1 && result.subagentsUnpriced == 1)
        #expect(ThreadCostDetailsView.note(result) == "Priced as claude-opus-5-5. Includes subagents' own tokens, each at its own model's price. "
            + "1 subagent left out: no price for muse-spark-1.3. 1 subagent left out: usage couldn't be read.")
        // The open thread on a model without a price hides the figure, as before.
        #expect(ThreadCostEstimate.breakdown(try thread("muse-spark-1.3", input: 1, output: 1), id: root) { tree[$0] ?? [] } == nil)
    }

    @Test func aThreadWithNoUsageOfItsOwnStillShowsItsSubagents() throws {
        var empty = try thread("claude-opus-5-5", input: 0, output: 0)
        empty.providerTurns = []
        let child = ThreadCostEstimate.own(try thread("claude-haiku-5-5", input: 1_000_000, output: 0))
        let result = try #require(ThreadCostEstimate.breakdown(empty, id: "env:root") { _ in [.init(id: "env:a", title: "A", own: child)] })
        #expect(result.models.isEmpty && abs(result.usd - 0.1) < 1e-9)
        #expect(ThreadCostEstimate.breakdown(empty, id: "env:root") { _ in [] } == nil)
    }

    /// The figure while a turn streams: each request replaces the turn's `tokenUsage`, and the total arrives at the end.
    @Test func theFigureHoldsStillWhileATurnRunsAndMovesOnceWhenItEnds() throws {
        var p = try thread("claude-opus-5-5", input: 1_000_000, output: 0)
        let done = try #require(ThreadCostEstimate.usd(p))
        func request(_ input: Double) -> JSONValue {
            .object(["id": .string("t2"), "status": .string("running"), "tokenUsage": .object(["inputTokens": .number(input), "outputTokens": .number(10), "usedTokens": .number(input)])])
        }
        // Requests of 50k, then 20k after a compaction, then 80k: the old figure followed them up and down.
        for input in [50_000.0, 20_000, 80_000] {
            p.providerTurns = [p.providerTurns[0], request(input)]
            #expect(ThreadCostEstimate.usd(p) == done)
        }
        p.providerTurns[1] = .object(["id": .string("t2"), "status": .string("completed"),
                                      "turnTokenUsage": .object(["inputTokens": .number(500_000), "outputTokens": .number(0)])])
        #expect(abs(try #require(ThreadCostEstimate.usd(p)) - (done + 2)) < 1e-9)
    }

    @Test func aTurnWithoutAnAttemptKeepsItsOwnRunsModelAfterASwitch() throws {
        var p = try thread("claude-opus-5-5", input: 0, output: 0)
        var first = try #require(p.runs.first)
        first.id = "run-old"; first.ordinal = 1; first.modelSelection = ModelSelection(instanceId: "claudeAgent", model: "claude-haiku-5-5")
        var latest = first
        latest.id = "run-new"; latest.ordinal = 99; latest.modelSelection = ModelSelection(instanceId: "claudeAgent", model: "claude-opus-5-5")
        p.runs = [first, latest]
        p.nodes = [ExecutionNode(id: "node-old", threadId: p.thread.id, runId: "run-old", parentNodeId: nil, rootNodeId: "node-old", kind: "root", status: "completed")]
        p.attempts = []
        p.providerTurns = [.object(["id": .string("t1"), "status": .string("completed"), "nodeId": .string("node-old"), "runAttemptId": .null,
                                    "turnTokenUsage": .object(["inputTokens": .number(1_000_000), "outputTokens": .number(0)])])]
        // Priced as haiku ($0.10), the run it ran in, not the latest run's opus ($4).
        let b = try #require(ThreadCostEstimate.breakdown(p))
        #expect(b.models == ["claude-haiku-5-5"] && abs(b.usd - 0.1) < 1e-9)
    }

    @Test func aSubagentThreadWithoutRunsIsPricedAtTheThreadsModel() throws {
        var p = try thread("claude-opus-5-5", input: 1_000_000, output: 0)
        p.runs = []
        guard case .object(var raw) = p.thread.raw else { Issue.record("thread isn't an object"); return }
        raw["modelSelection"] = .object(["instanceId": .string("codex"), "model": .string("gpt-6-luna")])
        p.thread = try JSONDecoder().decode(AppThread.self, from: JSONEncoder().encode(JSONValue.object(raw)))
        let b = try #require(ThreadCostEstimate.breakdown(p))
        #expect(b.models == ["gpt-6-luna"] && abs(b.usd - 0.1) < 1e-9)
    }

    @Test func theFigureWaitsForASubagentsFirstReadInsteadOfJumping() throws {
        let p = try thread("claude-opus-5-5", input: 1_000_000, output: 0)
        let child = ThreadCostEstimate.own(try thread("claude-haiku-5-5", input: 1_000_000, output: 0))
        #expect(ThreadCostEstimate.breakdown(p, id: "env:root") { _ in [.init(id: "env:a", title: "A", own: nil, reading: true)] } == nil)
        let read = try #require(ThreadCostEstimate.breakdown(p, id: "env:root") { _ in [.init(id: "env:a", title: "A", own: child)] })
        #expect(abs(read.usd - 4.1) < 1e-9)
        // A failed read shows the thread's own figure and says a subagent was left out.
        let failed = try #require(ThreadCostEstimate.breakdown(p, id: "env:root") { _ in [.init(id: "env:a", title: "A", own: nil)] })
        #expect(abs(failed.usd - 4) < 1e-9 && failed.subagentsUnread == 1)
    }
}
