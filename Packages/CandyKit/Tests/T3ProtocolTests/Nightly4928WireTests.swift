import Foundation
import Testing
@testable import T3Protocol

/// Wire changes between nightly 3824 and 4928 (docs/research/nightly-diff-4928-wire.md).
struct Nightly4928WireTests {
    static func json(_ text: String) -> JSONValue {
        try! JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    /// 201 changed files: a 4928 server sends the first 200 and the totals of all 201 (WireProjection.ts:27).
    static func checkpointJSON(truncated: Bool) -> String {
        let count = truncated ? 200 : 3
        let files = (0..<count).map { #"{"path":"src/f\#($0).swift","kind":"modified","additions":2,"deletions":1}"# }
        let total = truncated ? #","filesTotal":{"count":201,"additions":410,"deletions":205}"# : ""
        return #"{"id":"cp1","threadId":"t1","scopeId":"s1","runId":"r1","nodeId":"n1","parentCheckpointId":null,"#
            + #""ordinalWithinScope":0,"appRunOrdinal":1,"ref":"refs/t3/cp1","status":"ready","files":[\#(files.joined(separator: ","))]"#
            + total + #","capturedAt":"2026-11-19T00:00:00.000Z"}"#
    }

    @Test func checkpointFilesTotalDecodes() throws {
        let truncated = try Self.json(Self.checkpointJSON(truncated: true)).decode(as: Checkpoint.self)
        #expect(truncated.files.count == 200)
        #expect(truncated.filesTotal == CheckpointFileTotals(count: 201, additions: 410, deletions: 205))
        #expect(CheckpointFileTotals.of(files: truncated.files, filesTotal: truncated.filesTotal).count == 201)

        let full = try Self.json(Self.checkpointJSON(truncated: false)).decode(as: Checkpoint.self)
        #expect(full.filesTotal == nil)
        #expect(CheckpointFileTotals.of(files: full.files, filesTotal: nil) == CheckpointFileTotals(count: 3, additions: 6, deletions: 3))
    }

    @Test func checkpointTurnItemFilesTotalDecodes() throws {
        let item = try TurnItem(json: Self.json(#"""
            {"id":"i1","threadId":"t1","type":"checkpoint","runId":"r1","ordinal":3,"status":"completed",
             "updatedAt":"2026-11-19T00:00:00.000Z","checkpointId":"cp1","scopeId":"s1",
             "files":[{"path":"a","kind":"added","additions":1,"deletions":0}],
             "filesTotal":{"count":250,"additions":900,"deletions":12}}
            """#))
        #expect(item.filesTotal == CheckpointFileTotals(count: 250, additions: 900, deletions: 12))
        // Round trip keeps it, since the item encodes its raw object.
        let again = try TurnItem(json: JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(item)))
        #expect(again.filesTotal?.count == 250)
    }
}
