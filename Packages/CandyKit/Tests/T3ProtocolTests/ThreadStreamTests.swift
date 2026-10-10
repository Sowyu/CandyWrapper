import Foundation
import Testing
@testable import T3Protocol

/// Every `orchestration.subscribeThread` Chunk value in a recorded transcript, as raw JSON.
private func recordedThreadValues(_ name: String) throws -> [Data] {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let url = root.appendingPathComponent("fixtures/transcripts/\(name)")
    var ids = Set<String>()
    var values: [Data] = []
    for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
        guard let record = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
            record["kind"] as? String == "ws", let body = record["body"] as? [String: Any]
        else { continue }
        if record["dir"] as? String == "send", body["tag"] as? String == "orchestration.subscribeThread",
            let id = body["id"] as? String
        {
            ids.insert(id)
        } else if body["_tag"] as? String == "Chunk", let id = body["requestId"] as? String, ids.contains(id),
            let chunk = body["values"] as? [Any]
        {
            values += try chunk.map { try JSONSerialization.data(withJSONObject: $0) }
        }
    }
    return values
}

private func item(_ json: String) throws -> ThreadStreamItem {
    try JSONDecoder().decode(ThreadStreamItem.self, from: Data(json.utf8))
}

private let projectionJSON = """
    {"thread":{"id":"t1","title":"T","projectId":"p1","lineage":{"rootThreadId":"t1","parentThreadId":null,
     "relationshipToParent":null},"futureField":{"x":1}},
     "runs":[],"attempts":[],"nodes":[],"subagents":[],"providerSessions":[],"providerThreads":[],"providerTurns":[],
     "runtimeRequests":[],"messages":[],"plans":[],"checkpointScopes":[],"checkpoints":[],"contextHandoffs":[],
     "contextTransfers":[],"updatedAt":"2026-01-01T00:00:00.000Z",
     "turnItems":[{"id":"i0","threadId":"t1","type":"reasoning","ordinal":3,"status":"completed",
                   "updatedAt":"2026-01-01T00:00:00.000Z","text":"older"}],
     "visibleTurnItems":[
       {"position":0,"visibility":"local","sourceThreadId":"t1","sourceItemId":"i1","item":
         {"id":"i1","threadId":"t1","type":"user_message","ordinal":5,"status":"completed","runId":null,
          "updatedAt":"2026-01-01T00:00:00.000Z","messageId":"m1","text":"hi","newField":true}},
       {"position":1,"visibility":"local","sourceThreadId":"t1","sourceItemId":"i2","item":
         {"id":"i2","threadId":"t1","type":"hologram","ordinal":6,"status":"completed",
          "updatedAt":"2026-01-01T00:00:00.000Z"}}]}
    """

@Suite struct ThreadStreamDecodingTests {
    @Test(arguments: ["02-turn.jsonl", "03-turn2.jsonl", "04-threads.jsonl"])
    func decodesEveryRecordedThreadStreamItem(_ name: String) throws {
        let values = try recordedThreadValues(name)
        #expect(!values.isEmpty)
        var kinds: [String: Int] = [:]
        for value in values {
            let decoded = try JSONDecoder().decode(ThreadStreamItem.self, from: value)
            switch decoded {
            case .snapshot: kinds["snapshot", default: 0] += 1
            case .synchronized: kinds["synchronized", default: 0] += 1
            case .event: kinds["event", default: 0] += 1
            case .unknownEvent, .unknown: Issue.record("recorded item decoded as unknown: \(decoded)")
            }
        }
        #expect(kinds["snapshot"] == kinds["synchronized"])
        if name == "04-threads.jsonl" { #expect(kinds["snapshot"] == 14) }
    }

    @Test func decodesTheRecordedBoundedSnapshot() throws {
        let snapshots = try recordedThreadValues("03-turn2.jsonl").compactMap { value -> ThreadDetailSnapshot? in
            if case .snapshot(let s) = try JSONDecoder().decode(ThreadStreamItem.self, from: value) { return s }
            return nil
        }
        let bounded = try #require(snapshots.last)
        #expect(bounded.snapshotSequence == 198)
        #expect(bounded.historyCursor == .null && bounded.hasMoreHistory == false)
        #expect(bounded.latestLocalTurnOrdinal == .value(3_000_004))
        #expect(bounded.turnItemsOmitLocalVisible == true && bounded.hasProgressiveHistory)
        #expect(bounded.projection.turnItems.isEmpty && bounded.projection.visibleTurnItems.count == 19)
        // Restoring the compact form puts the local rows' items back in front of `turnItems`.
        let restored = bounded.restoringLocalVisibleTurnItems()
        #expect(restored.turnItems.map(\.id) == bounded.projection.visibleTurnItems.map(\.item.id))
        let file = try #require(restored.turnItems.first { $0.type == .fileChange })
        #expect(file.string("fileName")?.hasSuffix("notes.md") == true)
    }

    @Test func dropsUnknownItemTypesAndKeepsUnknownFields() throws {
        let projection = try JSONDecoder().decode(ThreadProjection.self, from: Data(projectionJSON.utf8))
        #expect(projection.visibleTurnItems.map(\.item.id) == ["i1"])
        #expect(projection.visibleTurnItems[0].item["newField"] == .bool(true))
        #expect(projection.thread.raw["futureField"]?["x"] == .number(1))
        // Round trip keeps the wire object.
        let again = try JSONDecoder().decode(ThreadProjection.self, from: JSONEncoder().encode(projection))
        #expect(again == projection)
    }

    @Test func unknownEventsStillCarryTheirSequence() throws {
        #expect(try item(#"{"kind":"event","sequence":9,"event":{"type":"thread.teleported","payload":{}}}"#)
            == .unknownEvent(sequence: 9, eventType: "thread.teleported"))
        let unknownItem = #"""
            {"kind":"event","sequence":10,"event":{"id":"e","type":"turn-item.updated","threadId":"t1",
             "occurredAt":"2026-01-01T00:00:00.000Z","payload":{"type":"hologram","id":"x"}}}
            """#
        #expect(try item(unknownItem) == .unknownEvent(sequence: 10, eventType: "turn-item.updated"))
        #expect(try item(#"{"kind":"heartbeat","sequence":11}"#) == .unknown(kind: "heartbeat", sequence: 11))
        #expect(try item(#"{"kind":"synchronized"}"#) == .synchronized)
    }

    @Test func aKnownEventWithABrokenPayloadStillFails() {
        let broken = #"""
            {"kind":"event","sequence":3,"event":{"id":"e","type":"run.updated","threadId":"t1",
             "occurredAt":"2026-01-01T00:00:00.000Z","payload":{"id":"r1"}}}
            """#
        #expect(throws: DecodingError.self) { try item(broken) }
    }

    @Test func legacySnapshotsHaveNoHistoryMeta() throws {
        let json = #"{"kind":"snapshot","snapshotSequence":4,"projection":"# + projectionJSON + "}"
        guard case .snapshot(let snapshot) = try item(json) else { Issue.record("not a snapshot"); return }
        #expect(snapshot.historyCursor == .absent && snapshot.hasMoreHistory == nil && !snapshot.hasProgressiveHistory)
        #expect(snapshot.restoringLocalVisibleTurnItems().turnItems.map(\.id) == ["i0"])
    }

    @Test func encodesSubscribeAndDiffInputsWithoutNilKeys() throws {
        let input = SubscribeThreadInput(threadId: "t1", requestCompletionMarker: true, acceptBoundedSnapshot: true, acceptCompactTurnItems: true)
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(input)) as? [String: Any]
        #expect(object?.keys.sorted() == ["acceptBoundedSnapshot", "acceptCompactTurnItems", "requestCompletionMarker", "threadId"])
        let diff = try JSONDecoder().decode(ThreadTurnDiff.self, from: Data(
            #"{"threadId":"t1","fromTurnCount":0,"toTurnCount":1,"diff":"diff --git a/x b/x\n"}"#.utf8))
        #expect(diff.toTurnCount == 1 && diff.diff.hasPrefix("diff --git"))
        #expect(ThreadHistoryRequest(threadId: "t 1", cursor: "a+b").path == "/api/orchestration/threads/t%201/history?cursor=a+b")
    }
}
