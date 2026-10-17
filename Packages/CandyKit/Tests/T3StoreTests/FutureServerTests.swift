import Foundation
import Testing
import T3Protocol
@testable import T3Store

struct FutureServerTests {
    @Test func recordedThreadSurvivesFutureFieldsCasesAndEvents() throws {
        let original = try #require(try recordedThreadStreams("20-nightly-3234.jsonl").first)
        let future = try #require(try recordedThreadStreams("21-future-server.jsonl").first)
        let before = replay(original), after = replay(future)
        let projection = try #require(after.projection)
        #expect(after.status == .live)
        #expect(projection.thread.id == before.projection?.thread.id)
        #expect(projection.thread.title == before.projection?.thread.title)
        let ids = Set(projection.visibleTurnItems.map(\.item.id))
        #expect(before.projection!.visibleTurnItems.allSatisfy { ids.contains($0.item.id) })
        #expect(after.lastSequence == (before.lastSequence ?? 0) + 3)
        let row = try #require(projection.visibleTurnItems.first { $0.item.id.rawValue == "future-item" })
        #expect(projection.visibleTurnItems.contains { $0.item.id.rawValue == "future-event-item" })
        let entry = WorkLog.entry(for: row)
        // T3 session-logic.ts:552-557: unknown items keep their data and use the type as a label.
        #expect(entry.label == "future activity")
        #expect(entry.toolData == row.item.raw)
    }
}
