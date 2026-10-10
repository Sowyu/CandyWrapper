import Foundation
import T3Protocol
import Testing
@testable import T3Store

/// The omitted-output marker and the `orchestration.getTurnItem` request and result.
@Suite struct TurnItemDetailTests {
    /// The recorded `ls -la && git status --short` call (03-turn2): settled, `outputOmitted`, no output.
    private func recordedCommand() throws -> ProjectedTurnItem {
        let projections = try recordedThreadStreams("03-turn2.jsonl").compactMap { replay($0).projection }
        let rows = projections.flatMap(\.visibleTurnItems)
        return try #require(rows.last { $0.item.type == .commandExecution && $0.item.outputOmitted })
    }

    @Test func theReducerKeepsTheOmittedMarker() throws {
        let row = try recordedCommand()
        #expect(row.item.output == nil)
        #expect(row.item.input?.stringValue == "ls -la && git status --short")
        #expect(TurnItemDetail.needsFetch(row.item))
        #expect(row.item.status == .completed)
        #expect(TurnItemDetail.revision(row.item) == row.item.updatedAt.raw)
    }

    @Test func theRequestNamesTheSourceItemAndRevision() throws {
        let row = try recordedCommand()
        let request = TurnItemDetail.request(row)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: String]
        #expect(json == [
            "threadId": row.sourceThreadId.rawValue,
            "itemId": row.sourceItemId.rawValue,
            "revision": row.item.updatedAt.raw,
        ])
    }

    @Test func aRunningItemKeepsOneRevision() {
        let item = turnItem(#"{"id":"i","type":"command_execution","input":"seq 1 9","outputOmitted":true,"status":"running","updatedAt":"2026-01-01T00:00:05Z"}"#)
        #expect(TurnItemDetail.revision(item) == "live")
    }

    @Test func whichItemsFetch() {
        #expect(!TurnItemDetail.needsFetch(turnItem(#"{"id":"i","type":"command_execution","input":"ls","output":"a"}"#)))
        #expect(TurnItemDetail.needsFetch(turnItem(#"{"id":"i","type":"dynamic_tool","toolName":"Read","input":{},"outputOmitted":true}"#)))
        #expect(TurnItemDetail.needsFetch(turnItem(#"{"id":"i","type":"dynamic_tool","toolName":"x","input":{"summary":"{…","truncated":true}}"#)))
        #expect(!TurnItemDetail.needsFetch(turnItem(#"{"id":"i","type":"dynamic_tool","toolName":"x","input":{"a":1}}"#)))
        #expect(!TurnItemDetail.needsFetch(turnItem(#"{"id":"i","type":"reasoning","text":"t","streaming":false,"outputOmitted":true}"#)))
    }

    @Test func resultsResolveToWhatTheRowShows() throws {
        let gone = decode(GetTurnItemResult.self, #"{"item":null}"#)
        #expect(TurnItemDetail.resolve(gone, wireType: .commandExecution) == .gone)

        let command = GetTurnItemResult(item: turnItem(#"{"id":"i","type":"command_execution","input":"ls","output":"a\nb\n"}"#))
        #expect(TurnItemDetail.resolve(command, wireType: .commandExecution) == .output("a\nb\n"))
        #expect(TurnItemDetail.resolve(command, wireType: .dynamicTool) == .mismatch)

        let blank = GetTurnItemResult(item: turnItem(#"{"id":"i","type":"command_execution","input":"true","output":"  "}"#))
        #expect(TurnItemDetail.resolve(blank, wireType: .commandExecution) == .output(nil))

        let claudeBash = GetTurnItemResult(item: turnItem(#"{"id":"i","type":"command_execution","input":"x","output":"{\"stdout\":\"out\",\"stderr\":\"err\",\"interrupted\":false}"}"#))
        #expect(TurnItemDetail.resolve(claudeBash, wireType: .commandExecution) == .output("out\nerr"))

        let mcp = GetTurnItemResult(item: turnItem(#"{"id":"i","type":"dynamic_tool","toolName":"t","input":{},"output":{"content":[{"type":"text","text":"one"},{"type":"text","text":"two"}],"isError":false}}"#))
        #expect(TurnItemDetail.resolve(mcp, wireType: .dynamicTool) == .output("one\ntwo"))
    }

    @Test func longOutputKeepsOnlyWhatTheBoxCanShow() {
        let long = (1...20000).map(String.init).joined(separator: "\n") + "\n… output truncated for transport"
        let item = turnItem(#"{"id":"i","type":"command_execution","input":"seq 1 20000","output":\#(String(data: try! JSONEncoder().encode(long), encoding: .utf8)!)}"#)
        guard case .output(let text?) = TurnItemDetail.resolve(GetTurnItemResult(item: item), wireType: .commandExecution) else {
            Issue.record("no output"); return
        }
        #expect(text.hasPrefix("1\n2\n3\n"))
        #expect(text.split(separator: "\n").count == TurnItemDetail.keptLines)
        #expect(text.utf8.count <= TurnItemDetail.keptBytes)
    }
}
