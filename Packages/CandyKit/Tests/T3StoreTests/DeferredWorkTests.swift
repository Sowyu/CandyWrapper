import Foundation
import T3Protocol
import Testing
@testable import T3Store

// Deferred work history (#26240): threadHistoryMerge.ts:86-180, threads.ts:727-860 and
// MessagesTimeline.logic.ts:1941-1972 at 4928.

private let emptyProjection = """
    {"thread":{"id":"thread-1","title":"T"},"runs":[],"attempts":[],"nodes":[],"subagents":[],
     "providerSessions":[],"providerThreads":[],"providerTurns":[],"runtimeRequests":[],"messages":[],"plans":[],
     "turnItems":[],"checkpointScopes":[],"checkpoints":[],"contextHandoffs":[],"contextTransfers":[],
     "visibleTurnItems":[],"updatedAt":"2026-01-01T00:00:00.000Z"}
    """

private func command(_ id: String, ordinal: Int, deferred: (cursor: String, count: Int, last: Int)? = nil) -> TurnItem {
    let work = deferred.map { #","deferredWork":{"cursor":"\#($0.cursor)","itemCount":\#($0.count),"lastOrdinal":\#($0.last)}"# } ?? ""
    return turnItem(#"{"id":"\#(id)","type":"command_execution","runId":"r1","ordinal":\#(ordinal),"input":"ls"\#(work)}"#)
}

private func answer(_ id: String, ordinal: Int) -> TurnItem {
    turnItem(#"{"id":"\#(id)","type":"assistant_message","runId":"r1","ordinal":\#(ordinal),"text":"done","messageId":"m-\#(id)"}"#)
}

private func projection(_ items: [TurnItem]) -> ThreadProjection {
    var p = decode(ThreadProjection.self, emptyProjection)
    p.turnItems = items
    p.visibleTurnItems = items.enumerated().map { ProjectedTurnItem(local: $1, position: $0) }
    return p
}

private func page(_ items: [TurnItem], next: String?) -> ThreadHistoryPage {
    ThreadHistoryPage(snapshotSequence: 1, items: items.map { ProjectedTurnItem(local: $0) }, nextCursor: next, hasMoreHistory: false)
}

private func ids(_ p: ThreadProjection?) -> [String] { p?.visibleTurnItems.map(\.item.id.rawValue) ?? [] }

@Suite struct DeferredWorkTests {
    @Test func optsInOnTheSnapshotPagesAndSubscription() throws {
        #expect(ThreadHistoryRequest.boundedSnapshotPath("t").hasSuffix("&deferWork=1"))
        #expect(ThreadHistoryRequest(threadId: "t", cursor: "c").path.contains("deferWork=1"))
        let work = ThreadHistoryRequest(threadId: "t", cursor: "c", throughEntryId: "a", view: .work).path
        #expect(work.contains("view=work") && work.contains("throughEntryId=a") && !work.contains("deferWork"))
        let input = ThreadReducer(threadId: "t").subscribeInput()
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(input)) as? [String: Any]
        #expect(object?["acceptDeferredWork"] as? Bool == true)
    }

    @Test func pagesMergeAtTheAnchorUntilTheGroupIsComplete() {
        var reducer = ThreadReducer(threadId: "thread-1")
        let anchor = command("w1", ordinal: 1, deferred: ("k1", 4, 4))
        reducer.applySnapshot(ThreadDetailSnapshot(snapshotSequence: 1, projection: projection([anchor, answer("a", ordinal: 5)])))
        let request = reducer.deferredWorkRequest(anchorId: "w1")
        #expect(request?.cursor == "k1" && request?.view == .work && request?.throughEntryId == "w1")

        // The server pages a group from its end; a row outside the group's ordinals is dropped.
        let (_, first) = reducer.applyDeferredWorkPage(page([command("w3", ordinal: 3), command("w4", ordinal: 4), command("x", ordinal: 9)], next: "k2"),
                                                       anchorId: "w1", requestCursor: "k1")
        #expect(first == .loaded(next: "k2"))
        #expect(ids(reducer.projection) == ["w1", "w3", "w4", "a"])
        #expect(reducer.projection?.visibleTurnItems.first?.item.deferredWork?.cursor == "k2")
        #expect(reducer.projection?.visibleTurnItems.map(\.position) == [0, 1, 2, 3])

        // A page for a cursor the anchor no longer holds is stale.
        #expect(reducer.applyDeferredWorkPage(page([], next: nil), anchorId: "w1", requestCursor: "k1").1 == .failed("Work history changed. Try again."))

        let (_, last) = reducer.applyDeferredWorkPage(page([command("w1", ordinal: 1), command("w2", ordinal: 2)], next: nil), anchorId: "w1", requestCursor: "k2")
        #expect(last == .loaded(next: nil))
        #expect(ids(reducer.projection) == ["w1", "w2", "w3", "w4", "a"])
        #expect(reducer.projection?.visibleTurnItems.first?.item.hasDeferredWork == false)
        #expect(reducer.projection?.turnItems.first { $0.id == "w1" }?.hasDeferredWork == false)
        #expect(reducer.deferredWorkRequest(anchorId: "w1") == nil)
        #expect(reducer.applyDeferredWorkPage(page([], next: nil), anchorId: "w1", requestCursor: "k2").1 == .noop)
    }

    /// Nothing is missing once a group opens: the deferred snapshot plus its pages equals the full one.
    @Test func anOpenedGroupMatchesTheFullThread() {
        let group = (1...200).map { command("w\($0)", ordinal: $0) }
        let full = projection(group + [answer("a", ordinal: 201)])
        var reducer = ThreadReducer(threadId: "thread-1")
        reducer.applySnapshot(ThreadDetailSnapshot(snapshotSequence: 1, projection: projection(
            [command("w1", ordinal: 1, deferred: ("k1", 200, 200)), answer("a", ordinal: 201)])))
        // The server pages from the group's end, newest page first.
        #expect(reducer.applyDeferredWorkPage(page(Array(group[100...]), next: "k2"), anchorId: "w1", requestCursor: "k1").1 == .loaded(next: "k2"))
        #expect(reducer.applyDeferredWorkPage(page(Array(group[..<100]), next: nil), anchorId: "w1", requestCursor: "k2").1 == .loaded(next: nil))
        #expect(ids(reducer.projection) == ids(full))
        #expect(reducer.projection?.visibleTurnItems == full.visibleTurnItems)
    }

    @Test func aPageThatDoesNotAdvanceFails() {
        var reducer = ThreadReducer(threadId: "thread-1")
        reducer.applySnapshot(ThreadDetailSnapshot(snapshotSequence: 1, projection: projection([command("w1", ordinal: 1, deferred: ("k1", 3, 3))])))
        #expect(reducer.applyDeferredWorkPage(page([], next: "k1"), anchorId: "w1", requestCursor: "k1").1 == .failed("Work history did not advance."))
    }

    @Test func anUpdateKeepsTheAnchorsCursor() throws {
        var reducer = ThreadReducer(threadId: "thread-1")
        reducer.applySnapshot(ThreadDetailSnapshot(snapshotSequence: 1, projection: projection([command("w1", ordinal: 1, deferred: ("k1", 3, 3))])))
        let event = ThreadEvent(id: "e", type: "turn-item.updated", threadId: "thread-1", runId: nil, occurredAt: "2026-01-02T00:00:00.000Z",
                                payload: .turnItem(command("w1", ordinal: 1)))
        reducer.apply([.event(sequence: 2, event: event)])
        #expect(reducer.projection?.visibleTurnItems.first?.item.deferredWork?.cursor == "k1")
    }

    @Test func aPlainPageInterleavesAtSharedRows() {
        // #29711: rows the page shares with the window keep their places, new ones go before the next shared row.
        let current = projection([command("b", ordinal: 2), command("d", ordinal: 4)])
        let merged = ThreadReduction.mergeOlderHistory(current, [command("a", ordinal: 1), command("b", ordinal: 2), command("c", ordinal: 3)]
            .map { ProjectedTurnItem(local: $0) })
        #expect(ids(merged) == ["a", "b", "c", "d"])
    }

    @Test func aTurnFoldNamesItsDeferredAnchors() {
        var anchor = WorkLogEntry(id: "w1", createdAt: "2026-01-01T00:00:05Z", runId: "r1", label: "Ran command", tone: .tool)
        anchor.projectedItem = ProjectedTurnItem(local: command("w1", ordinal: 1, deferred: ("k1", 200, 200)))
        let entries: [TimelineEntry] = [
            .message("u", ChatMessage(id: "u", role: .user, text: "go", runId: "r1", createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z")),
            .work("w1", anchor),
            .message("a", ChatMessage(id: "a", role: .assistant, text: "done", runId: "r1", createdAt: "2026-01-01T00:00:20Z", updatedAt: "2026-01-01T00:00:22Z")),
        ]
        var input = TimelineRowsInput(entries: entries)
        input.latestRun = TimelineLatestRun(runId: "r1", status: .completed, startedAt: "2026-01-01T00:00:00Z", completedAt: "2026-01-01T00:00:22Z")
        let collapsed = TimelineRows.derive(input)
        let fold = collapsed.first { $0.id == "turn-fold:r1" }
        #expect(fold?.deferredWorkItemIds == ["w1"] && fold?.isExpandedFold == false)
        #expect(!collapsed.contains { $0.id == "w1" })
        input.expandedRunIds = ["r1"]
        #expect(TimelineRows.derive(input).first { $0.id == "turn-fold:r1" }?.isExpandedFold == true)
    }
}
