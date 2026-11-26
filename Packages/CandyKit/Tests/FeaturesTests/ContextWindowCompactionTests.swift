import Testing
import T3Protocol
@testable import Features

/// #39024 (5258 client-runtime contextWindow.test.ts): a completed compaction newer than the latest usage report
/// fills the meter with its `afterTokenCount`, under the report's window size.
struct ContextWindowCompactionTests {
    private func projection(usageAt: String, compactedAt: String, status: String = "completed", providerThreadId: String = "p") throws -> ThreadProjection {
        let compaction: JSONValue = .object([
            "id": .string("c"), "threadId": .string("t"), "type": .string("compaction"), "ordinal": .number(1), "status": .string(status),
            "providerThreadId": .string(providerThreadId), "beforeTokenCount": .number(180_000), "afterTokenCount": .number(20_000),
            "startedAt": .string(compactedAt), "completedAt": .string(compactedAt), "updatedAt": .string(compactedAt),
        ])
        return try JSONValue.object([
            "thread": .object(["id": .string("t"), "activeProviderThreadId": .string("p")]), "updatedAt": .string(compactedAt),
            "providerThreads": .array([.object(["id": .string("p")])]),
            "providerTurns": .array([.object(["id": .string("pt"), "providerThreadId": .string("p"), "tokenUsage": .object([
                "usedTokens": .number(190_000), "maxTokens": .number(200_000), "updatedAt": .string(usageAt)])])]),
            "visibleTurnItems": .array([.object(["position": .number(0), "visibility": .string("local"), "sourceThreadId": .string("t"),
                                                 "sourceItemId": .string("c"), "item": compaction])]),
        ]).decode(as: ThreadProjection.self)
    }

    @Test func newerCompletedCompactionWinsOverStaleLiveUsage() throws {
        let u = try #require(ThreadContextWindowUsage.derive(projection(usageAt: "2026-11-25T10:00:00.000Z", compactedAt: "2026-11-25T10:05:00.000Z")))
        #expect(u.used == 20_000)
        #expect(u.maximum == 200_000)
        #expect(u.total == 180_000)
    }

    @Test func usageAtOrAfterTheCompactionStays() throws {
        let same = try #require(ThreadContextWindowUsage.derive(projection(usageAt: "2026-11-25T10:05:00.000Z", compactedAt: "2026-11-25T10:05:00.000Z")))
        #expect(same.used == 190_000)
        let running = try #require(ThreadContextWindowUsage.derive(projection(usageAt: "2026-11-25T10:00:00.000Z", compactedAt: "2026-11-25T10:05:00.000Z", status: "running")))
        #expect(running.used == 190_000)
        let retired = try #require(ThreadContextWindowUsage.derive(projection(usageAt: "2026-11-25T10:00:00.000Z", compactedAt: "2026-11-25T10:05:00.000Z", providerThreadId: "old")))
        #expect(retired.used == 190_000)
    }
}
