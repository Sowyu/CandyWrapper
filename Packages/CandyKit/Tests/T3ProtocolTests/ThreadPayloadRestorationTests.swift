import Foundation
import Testing
@testable import T3Protocol

private let wireDate = "2026-01-01T00:00:00.000Z"

private func json(_ text: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
}

private func snapshotJSON(_ projection: JSONValue, ids: [JSONValue]? = nil) -> JSONValue {
    var fields: [String: JSONValue] = ["kind": .string("snapshot"), "snapshotSequence": .number(10), "projection": projection]
    fields["ids"] = ids.map(JSONValue.array)
    return .object(fields)
}

private func wireProjection(_ fields: [String: JSONValue] = [:]) -> JSONValue {
    var base: [String: JSONValue] = [
        "thread": .object(["id": .string("t"), "title": .string("T")]), "updatedAt": .string(wireDate),
    ]
    for key in ["runs", "attempts", "nodes", "subagents", "providerSessions", "providerThreads", "providerTurns",
                "runtimeRequests", "messages", "plans", "turnItems", "checkpointScopes", "checkpoints",
                "contextHandoffs", "contextTransfers", "visibleTurnItems"] { base[key] = .array([]) }
    base.merge(fields) { _, new in new }
    return .object(base)
}

private func bodyItem(_ fields: [String: JSONValue]) -> JSONValue {
    var base: [String: JSONValue] = [
        "id": .string("i"), "threadId": .string("t"), "ordinal": .number(1),
        "status": .string("completed"), "updatedAt": .string(wireDate),
    ]
    base.merge(fields) { _, new in new }
    return .object(base)
}

private func wireEvent(_ type: String, _ payload: JSONValue, sequence: Int = 11) -> JSONValue {
    .object(["kind": .string("event"), "sequence": .number(Double(sequence)), "event": .object([
        "id": .string("e"), "type": .string(type), "threadId": .string("t"),
        "occurredAt": .string(wireDate), "payload": payload,
    ])])
}

@Suite struct ThreadPayloadRestorationTests {
    @Test func restoresExactRecordSlotsAndConsumesTheTable() throws {
        let raw = try json(#"""
        {"records":[{"id":0,"parentIds":[1,2,null,"plain"],"count":2,
          "item":{"ownerId":1,"legacyId":2,"nested":{"id":99}},
          "input":{"id":99},"lineage":{"rootThreadId":99}}],"ids":["row","parent",3]}
        """#)
        let expanded = try ThreadPayloadRestoration.expandIds(raw, container: nil)
        let row = try #require(expanded["records"]?.arrayValue?.first)
        #expect(row["id"] == .string("row"))
        #expect(row["parentIds"] == .array([.string("parent"), .number(3), .null, .string("plain")]))
        #expect(row["item"]?["legacyId"] == .number(3))
        #expect(row["item"]?["nested"]?["id"] == .number(99))
        #expect(row["input"]?["id"] == .number(99))
        #expect(row["lineage"]?["rootThreadId"] == .number(99))
        #expect(row["count"] == .number(2) && expanded["ids"] == nil)
        #expect(try ThreadPayloadRestoration.expandIds(expanded, container: nil) == expanded)
    }

    @Test(arguments: [-1.0, 0.5, 2.0, 1e30]) func rejectsInvalidReferencesEvenInUnknownOptionalSlots(_ index: Double) {
        let raw: JSONValue = .object(["records": .array([.object(["futureId": .number(index)])]), "ids": .array([.string("x")])])
        #expect(throws: DecodingError.self) { try ThreadPayloadRestoration.expandIds(raw, container: nil) }
    }

    @Test func restoresSnapshotBodiesBeforeCompactedLocalItems() throws {
        let text = bodyItem(["type": .string("assistant_message"), "messageId": .string("m"), "text": .string(""), "textOmitted": .bool(true)])
        let checkpoint = bodyItem(["type": .string("checkpoint"), "checkpointId": .string("c"), "files": .array([]), "filesOmitted": .bool(true)])
        let subagent = bodyItem(["type": .string("subagent"), "subagentId": .string("s"), "prompt": .string(""), "result": .null,
                                 "promptOmitted": .bool(true), "resultOmitted": .bool(true)])
        let files: JSONValue = .array([.object(["path": .string("file.swift"), "additions": .number(2)])])
        let projection = wireProjection([
            "messages": .array([.object(["id": .string("m"), "threadId": .string("t"), "role": .string("assistant"),
                                         "text": .string("answer"), "streaming": .bool(false), "createdAt": .string(wireDate), "updatedAt": .string(wireDate)])]),
            "checkpoints": .array([.object(["id": .string("c"), "threadId": .string("t"), "scopeId": .string("scope"),
                                            "ref": .string("ref"), "status": .string("completed"), "capturedAt": .string(wireDate), "files": files])]),
            "subagents": .array([.object(["id": .string("s"), "prompt": .string("prompt"), "result": .string("result")])]),
            "turnItems": .array([checkpoint, subagent]),
            "visibleTurnItems": .array([.object(["position": .number(0), "visibility": .string("local"), "sourceThreadId": .string("t"),
                                                 "sourceItemId": .string("i"), "item": text])]),
        ])
        var raw = try #require(snapshotJSON(projection).objectValue)
        raw["turnItemsOmitLocalVisible"] = .bool(true)
        let snapshot = try JSONValue.object(raw).decode(as: ThreadDetailSnapshot.self)
        #expect(snapshot.projection.visibleTurnItems[0].item.text == "answer")
        #expect(snapshot.projection.turnItems[0]["files"] == files)
        #expect(snapshot.projection.turnItems[1].string("prompt") == "prompt")
        #expect(snapshot.projection.turnItems[1].string("result") == "result")
        #expect(snapshot.restoringLocalVisibleTurnItems().turnItems.count == 3)
        for item in snapshot.restoringLocalVisibleTurnItems().turnItems {
            #expect(item.raw["textOmitted"] == nil && item.raw["filesOmitted"] == nil && item.raw["promptOmitted"] == nil)
        }
        let encoded = try JSONEncoder().encode(snapshot)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("Omitted"))
    }

    @Test func snapshotAndHistoryDecodersRestoreCompactIds() throws {
        let item = bodyItem(["id": .number(1), "threadId": .number(0), "type": .string("reasoning"), "text": .string("body")])
        let row: JSONValue = .object(["position": .number(0), "visibility": .string("local"), "sourceThreadId": .number(0), "sourceItemId": .number(1), "item": item])
        let ids: [JSONValue] = [.string("t"), .string("i")]
        let raw = snapshotJSON(wireProjection(["thread": .object(["id": .number(0)]), "visibleTurnItems": .array([row])]), ids: ids)
        let snapshot = try raw.decode(as: ThreadDetailSnapshot.self)
        #expect(snapshot.projection.thread.id == "t" && snapshot.projection.visibleTurnItems[0].item.id == "i")
        guard case .snapshot(let streamSnapshot) = try raw.decode(as: ThreadStreamItem.self) else { Issue.record("Missing snapshot"); return }
        #expect(streamSnapshot == snapshot)
        let page: JSONValue = .object(["snapshotSequence": .number(10), "items": .array([row]), "nextCursor": .null, "hasMoreHistory": .bool(false), "ids": .array(ids)])
        #expect(try page.decode(as: ThreadHistoryPage.self).items[0].item.threadId == "t")
    }

    @Test func streamRestoresRepeatedSubagentsAndAllBodyKinds() throws {
        var restorer = ThreadWireRestorer()
        _ = try restorer.decode(snapshotJSON(wireProjection()))
        let record: JSONValue = .object(["id": .string("s"), "prompt": .string("prompt"), "result": .null])
        _ = try restorer.decode(wireEvent("subagent.updated", record))
        let omitted: JSONValue = .object(["id": .string("s"), "prompt": .string(""), "promptOmitted": .bool(true), "result": .string("done")])
        guard case .event(_, let event) = try restorer.decode(wireEvent("subagent.updated", omitted)), case .json(let subagent) = event.payload else { Issue.record("Missing subagent"); return }
        #expect(subagent["prompt"] == .string("prompt") && subagent["promptOmitted"] == nil)
        let item = bodyItem(["type": .string("subagent"), "subagentId": .string("s"), "promptOmitted": .bool(true), "resultOmitted": .bool(true)])
        guard case .event(_, let turnEvent) = try restorer.decode(wireEvent("turn-item.updated", item)), case .turnItem(let turn) = turnEvent.payload else { Issue.record("Missing item"); return }
        #expect(turn.string("prompt") == "prompt" && turn.string("result") == "done")
        #expect(throws: DecodingError.self) { try wireEvent("turn-item.updated", item).decode(as: ThreadStreamItem.self) }
    }

    @Test func missingReferencesThrowAndSnapshotResetForgetsOldBodies() throws {
        var restorer = ThreadWireRestorer()
        let item = bodyItem(["type": .string("assistant_message"), "messageId": .string("missing"), "textOmitted": .bool(true)])
        #expect(throws: DecodingError.self) { try restorer.decode(wireEvent("turn-item.updated", item)) }
        #expect(throws: DecodingError.self) { try snapshotJSON(wireProjection(["turnItems": .array([item])])).decode(as: ThreadDetailSnapshot.self) }
        _ = try restorer.decode(wireEvent("subagent.updated", .object(["id": .string("s"), "prompt": .string("old"), "result": .null])))
        _ = try restorer.decode(snapshotJSON(wireProjection()))
        #expect(throws: DecodingError.self) {
            try restorer.decode(wireEvent("subagent.updated", .object(["id": .string("s"), "promptOmitted": .bool(true), "result": .null])))
        }
    }

    @Test func optInsMatchEndpointCapabilities() throws {
        let path = ThreadHistoryRequest.boundedSnapshotPath("t")
        #expect(path.hasSuffix("compactTurnItems=1&dedupeBodies=1&compactIds=1"))
        let history = ThreadHistoryRequest(threadId: "t", cursor: "a+b", throughEntryId: "i+1", view: .activity).path
        #expect(history.contains("compactIds=1") && !history.contains("dedupeBodies"))
        #expect(history.contains("a%2Bb") && history.contains("i%2B1"))
        let legacy = SubscribeThreadInput(threadId: "t")
        let encoded = try JSONEncoder().encode(legacy)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("accept"))
    }
}
