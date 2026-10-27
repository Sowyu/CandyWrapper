import Testing
import T3Protocol
@testable import Features

/// Redesign's Context legend: the thread's items by category, the fixed part read off the per-turn reports,
/// tool output as what's left.
struct ThreadContextEstimateTests {
    private func at(_ s: Int) -> JSONValue { .string(String(format: "2026-10-22T10:00:%02d.000Z", s)) }
    private func item(_ id: String, _ type: String, _ s: Int, _ extra: [String: JSONValue] = [:]) -> JSONValue {
        let base: [String: JSONValue] = ["id": .string(id), "threadId": .string("t"), "type": .string(type), "ordinal": .number(Double(s)),
                                         "status": .string("completed"), "startedAt": at(s), "updatedAt": at(s)]
        return .object(["position": .number(Double(s)), "visibility": .string("local"), "sourceThreadId": .string("t"), "sourceItemId": .string(id),
                        "item": .object(base.merging(extra) { $1 })])
    }
    private func report(_ s: Int, _ used: Double) -> JSONValue {
        .object(["id": .string("pt\(s)"), "tokenUsage": .object(["usedTokens": .number(used), "updatedAt": at(s)])])
    }
    private func estimate(_ items: [JSONValue], _ reports: [JSONValue], used: Double, earlier: Bool = false) throws -> ThreadContextEstimate {
        let projection = try JSONValue.object(["thread": .object(["id": .string("t")]), "visibleTurnItems": .array(items),
                                               "providerTurns": .array(reports), "updatedAt": at(59)]).decode(as: ThreadProjection.self)
        return try #require(ThreadContextEstimate.estimate(projection, used: used, hasEarlierHistory: earlier))
    }
    private func text(_ n: Int) -> JSONValue { .string(String(repeating: "a", count: n)) }
    private func sum(_ e: ThreadContextEstimate) -> Double { e.categories.map(\.value).reduce(0, +) }

    @Test func splitsTheThreadAndReadsTheFixedPartOffTheFirstTurn() throws {
        let image: JSONValue = .object(["type": .string("image"), "id": .string("a1"), "name": .string("x.png"), "mimeType": .string("image/png"), "sizeBytes": .number(10)])
        let pasted: JSONValue = .object(["type": .string("file"), "id": .string("a2"), "name": .string("p.txt"), "mimeType": .string("text/plain"), "sizeBytes": .number(800),
                                         "source": .object(["_tag": .string("pasted-text")])])
        let e = try estimate([
            item("u1", "user_message", 1, ["text": text(400), "attachments": .array([image, pasted])]),
            item("a1", "assistant_message", 2, ["text": text(200), "streaming": .bool(false)]),
            item("u2", "user_message", 4, ["text": text(40), "attachments": .array([])]),
            item("c1", "command_execution", 5, ["input": text(400), "outputOmitted": .bool(true)]),
        ], [report(3, 10_000), report(6, 30_000)], used: 30_000)
        #expect(e.messages == 100 + 200 + 10)
        #expect(e.replies == 50)
        #expect(e.images == 1_600)
        #expect(e.system == 10_000 - 1_950)
        #expect(e.tools > 100)
        #expect(sum(e) == 30_000)
    }

    @Test func floorsTheFixedPartAtZero() throws {
        // The first report is smaller than what the thread already holds.
        let e = try estimate([item("u1", "user_message", 1, ["text": text(400), "attachments": .array([])])],
                             [report(2, 50)], used: 10_000)
        #expect(e.system == 0)
        #expect(e.tools == 9_900)
        #expect(sum(e) == 10_000)
    }

    @Test func scalesTheThreadDownWhenItOvershootsTheReport() throws {
        let e = try estimate([item("u1", "user_message", 1, ["text": text(800), "attachments": .array([])]),
                              item("a1", "assistant_message", 2, ["text": text(400), "streaming": .bool(false)])], [], used: 150)
        #expect(e.system == 0 && e.tools == 0)
        #expect(e.messages == 100 && e.replies == 50)
    }

    @Test func countsOnlyFromTheLastCompaction() throws {
        let e = try estimate([
            item("u1", "user_message", 1, ["text": text(40_000), "attachments": .array([])]),
            item("k1", "compaction", 3, ["summary": text(400)]),
            item("u2", "user_message", 4, ["text": text(40), "attachments": .array([])]),
        ], [report(2, 50), report(5, 5_000)], used: 5_000)
        #expect(e.messages == 10)
        #expect(e.replies == 100)
        #expect(e.system == 4_890)
        #expect(sum(e) == 5_000)
    }

    @Test func aFailedCompactionKeepsTheEarlierHistory() throws {
        let e = try estimate([
            item("u1", "user_message", 1, ["text": text(4_000), "attachments": .array([])]),
            item("k1", "compaction", 3, ["summary": text(400), "status": .string("failed")]),
            item("u2", "user_message", 4, ["text": text(40), "attachments": .array([])]),
        ], [], used: 100_000)
        #expect(e.messages == 1_000 + 10)
    }

    /// A long thread loads only its latest page, so the history before it reads as part of the fixed figure. The
    /// legend names that row for both, as on 2026-10-27 the Conductor showed 483K of 518K as "System prompt and tools".
    @Test func aPartialWindowNamesTheEarlierMessages() throws {
        let items = [item("u9", "user_message", 10, ["text": text(400), "attachments": .array([])]),
                     item("a9", "assistant_message", 11, ["text": text(400), "streaming": .bool(false)])]
        let e = try estimate(items, [report(12, 483_200)], used: 483_200, earlier: true)
        #expect(e.includesEarlier)
        #expect(e.categories.first?.name == "Prompt and earlier messages")
        #expect(e.system == 483_200 - 200)
        #expect(sum(e) == 483_200)
        // With the whole history loaded the same split reads as the system prompt.
        let whole = try estimate(items, [report(12, 483_200)], used: 483_200)
        #expect(!whole.includesEarlier && whole.categories.first?.name == "System prompt and tools")
    }

    @Test func aCompactionInTheWindowCutsOffTheUnloadedHistory() throws {
        let e = try estimate([
            item("k1", "compaction", 3, ["summary": text(400)]),
            item("u2", "user_message", 4, ["text": text(40), "attachments": .array([])]),
        ], [report(5, 20_000)], used: 20_000, earlier: true)
        #expect(!e.includesEarlier)
        #expect(e.categories.first?.name == "System prompt and tools")
    }
}
