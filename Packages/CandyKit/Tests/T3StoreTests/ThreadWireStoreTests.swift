import Foundation
import T3Protocol
import Testing
@testable import T3Store

private let bodyDate = "2026-01-01T00:00:00.000Z"

private func bodyProjection() throws -> ThreadProjection {
    try JSONDecoder().decode(ThreadProjection.self, from: Data("""
    {"thread":{"id":"t","title":"T"},"runs":[],"attempts":[],"nodes":[],"subagents":[],
     "providerSessions":[],"providerThreads":[],"providerTurns":[],"runtimeRequests":[],"messages":[],"plans":[],
     "turnItems":[],"checkpointScopes":[],"checkpoints":[],"contextHandoffs":[],"contextTransfers":[],
     "visibleTurnItems":[],"updatedAt":"\(bodyDate)"}
    """.utf8))
}

private func bodyMessage(_ text: String) -> ConversationMessage {
    ConversationMessage(id: "m", threadId: "t", runId: nil, role: "assistant", text: text, streaming: false,
                        createdAt: T3Timestamp(bodyDate), updatedAt: T3Timestamp(bodyDate))
}

private func bodyEvent(_ type: String, sequence: Int, payload: JSONValue) -> JSONValue {
    .object(["kind": .string("event"), "sequence": .number(Double(sequence)), "event": .object([
        "id": .string("e"), "type": .string(type), "threadId": .string("t"), "occurredAt": .string(bodyDate), "payload": payload,
    ])])
}

private func bodyRecord(_ text: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(bodyMessage(text)))
}

private func omittedMessage(ordinal: Int = 1) -> JSONValue {
    .object(["id": .string("i"), "threadId": .string("t"), "type": .string("assistant_message"), "ordinal": .number(Double(ordinal)),
             "status": .string("completed"), "updatedAt": .string(bodyDate), "messageId": .string("m"),
             "text": .string(""), "textOmitted": .bool(true)])
}

@Suite struct ThreadWireStoreTests {
    @Test func transportRecordsSurviveSequenceDeduplicationAndReconnect() async throws {
        let store = ThreadStore(threadId: "t", onChange: {})
        await store.applySnapshot(ThreadDetailSnapshot(snapshotSequence: 20, projection: try bodyProjection()))
        // A new subscription can deliver overlapping old records; the server remembers these
        // before the reducer drops their sequence. Its following item refers to that body.
        try await store.applyWire(bodyEvent("message.updated", sequence: 19, payload: bodyRecord("replayed body")))
        #expect(await store.projection?.messages.isEmpty == true)
        let input = await store.subscribeInput()
        #expect(input.afterSequence == 20 && input.acceptDedupedBodies == true && input.acceptCompactIds == true)
        try await store.applyWire(bodyEvent("turn-item.updated", sequence: 21, payload: omittedMessage()))
        #expect(await store.projection?.visibleTurnItems.first?.item.text == "replayed body")
        #expect(await store.lastSequence == 21)
    }

    @Test func resetKeepsVisibleDataButRequiresAFreshSnapshotAndFreshBodies() async throws {
        let store = ThreadStore(threadId: "t", onChange: {})
        var projection = try bodyProjection()
        projection.messages = [bodyMessage("cached body")]
        await store.applySnapshot(ThreadDetailSnapshot(snapshotSequence: 20, projection: projection))
        try await store.applyWire(bodyEvent("turn-item.updated", sequence: 21, payload: omittedMessage()))
        let before = await store.projection
        await store.resetForResynchronization()
        #expect(await store.projection == before)
        #expect(await store.lastSequence == nil)
        #expect(await store.status == .synchronizing)
        #expect(await store.subscribeInput().afterSequence == nil)
        do {
            try await store.applyWire(bodyEvent("turn-item.updated", sequence: 22, payload: omittedMessage()))
            Issue.record("Reset retained an old body reference")
        } catch is DecodingError {}
        #expect(await store.lastSequence == nil)
        #expect(await store.projection == before)
        projection.messages = [bodyMessage("fresh body")]
        await store.applySnapshot(ThreadDetailSnapshot(snapshotSequence: 30, projection: projection))
        try await store.applyWire(bodyEvent("turn-item.updated", sequence: 31, payload: omittedMessage()))
        #expect(await store.projection?.visibleTurnItems.first?.item.text == "fresh body")
    }

    @Test func cachedAndHttpSnapshotsSeedBodySources() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cw-wire-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ThreadCache(directory: directory)
        let key = ThreadCache.Key(environmentId: "sandbox", threadId: "t")
        var projection = try bodyProjection()
        projection.messages = [bodyMessage("disk body")]
        await cache.offer(key, sequence: 10, projection: projection, history: ThreadHistoryMeta())
        await cache.flush(key)
        let store = ThreadStore(threadId: "t", cache: cache, environmentId: "sandbox", onChange: {})
        #expect(await store.subscribeInput().afterSequence == 10)
        try await store.applyWire(bodyEvent("turn-item.updated", sequence: 11, payload: omittedMessage()))
        #expect(await store.projection?.visibleTurnItems.first?.item.text == "disk body")
        projection.messages = [bodyMessage("http body")]
        await store.applySnapshot(ThreadDetailSnapshot(snapshotSequence: 20, projection: projection))
        try await store.applyWire(bodyEvent("turn-item.updated", sequence: 21, payload: omittedMessage()))
        #expect(await store.projection?.visibleTurnItems.first?.item.text == "http body")
        await store.flushCache()
    }

    @Test func partialWindowFilteringCannotDiscardBodySources() async throws {
        let store = ThreadStore(threadId: "t", onChange: {})
        await store.applySnapshot(ThreadDetailSnapshot(snapshotSequence: 10, projection: try bodyProjection(),
                                                       historyCursor: .value("older"), hasMoreHistory: true, latestLocalTurnOrdinal: .value(50)))
        try await store.applyWire(bodyEvent("message.updated", sequence: 11, payload: bodyRecord("kept body")))
        try await store.applyWire(bodyEvent("turn-item.updated", sequence: 12, payload: omittedMessage(ordinal: 1)))
        #expect(await store.projection?.turnItems.isEmpty == true)
        try await store.applyWire(bodyEvent("turn-item.updated", sequence: 13, payload: omittedMessage(ordinal: 51)))
        #expect(await store.projection?.visibleTurnItems.first?.item.text == "kept body")
    }

    @Test func replacedSubscriptionsCannotChangeBodiesSnapshotsOrResetTheCursor() async throws {
        let store = ThreadStore(threadId: "t", onChange: {})
        let old = UUID(), current = UUID()
        await store.applySnapshot(ThreadDetailSnapshot(snapshotSequence: 10, projection: try bodyProjection()))
        _ = await store.subscribeInput(subscription: old)
        try await store.applyWire(bodyEvent("message.updated", sequence: 11, payload: bodyRecord("old body")), subscription: old)
        _ = await store.subscribeInput(subscription: current)
        try await store.applyWire(bodyEvent("message.updated", sequence: 12, payload: bodyRecord("current body")), subscription: current)
        // A stale source would poison the next omitted item even though reduction drops its sequence.
        try await store.applyWire(bodyEvent("message.updated", sequence: 11, payload: bodyRecord("late old body")), subscription: old)
        try await store.applyWire(bodyEvent("turn-item.updated", sequence: 13, payload: omittedMessage()), subscription: current)
        #expect(await store.projection?.visibleTurnItems.first?.item.text == "current body")
        // Stale malformed input must be ignored before restoration too, not trigger recovery.
        try await store.applyWire(.object(["kind": .string("snapshot"), "ids": .array([])]), subscription: old)
        let stale = ThreadDetailSnapshot(snapshotSequence: 1, projection: try bodyProjection())
        var raw = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(stale)).objectValue!
        raw["kind"] = .string("snapshot")
        try await store.applyWire(.object(raw), subscription: old)
        await store.applySnapshot(stale, subscription: old)
        await store.resetForResynchronization(subscription: old)
        #expect(await store.lastSequence == 13)
        #expect(await store.projection?.visibleTurnItems.first?.item.text == "current body")
        await store.resetForResynchronization(subscription: current)
        #expect(await store.subscribeInput(subscription: current).afterSequence == nil)
        do {
            try await store.applyWire(bodyEvent("turn-item.updated", sequence: 14, payload: omittedMessage()), subscription: current)
            Issue.record("A recovery retry reseeded invalidated body sources")
        } catch is DecodingError {}
    }

    @Test func cancelledPayloadCannotReclaimTheStoreAfterAHandoff() async throws {
        let store = ThreadStore(threadId: "t", onChange: {})
        let old = UUID(), current = UUID()
        await store.applySnapshot(ThreadDetailSnapshot(snapshotSequence: 10, projection: try bodyProjection()))
        _ = await store.subscribeInput(subscription: old)
        _ = await store.subscribeInput(subscription: current)
        // Cancelled payload closures still execute after an awaited bootstrap returns.
        let delayed = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await store.subscribeInput(subscription: old)
        }
        _ = await delayed.value
        try await store.applyWire(bodyEvent("message.updated", sequence: 11, payload: bodyRecord("owner body")), subscription: current)
        try await store.applyWire(bodyEvent("turn-item.updated", sequence: 12, payload: omittedMessage()), subscription: current)
        #expect(await store.projection?.visibleTurnItems.first?.item.text == "owner body")
        #expect(await store.lastSequence == 12)
    }

}
