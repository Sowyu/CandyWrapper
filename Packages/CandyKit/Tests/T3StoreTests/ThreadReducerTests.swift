import Foundation
import T3Protocol
import Testing
@testable import T3Store

private let emptyProjection = """
    {"thread":{"id":"thread-1","title":"T"},"runs":[],"attempts":[],"nodes":[],"subagents":[],
     "providerSessions":[],"providerThreads":[],"providerTurns":[],"runtimeRequests":[],"messages":[],"plans":[],
     "turnItems":[],"checkpointScopes":[],"checkpoints":[],"contextHandoffs":[],"contextTransfers":[],
     "visibleTurnItems":[],"updatedAt":"2026-01-01T00:00:00.000Z"}
    """

private func projection(_ items: [TurnItem] = [], runs: [Run] = []) -> ThreadProjection {
    var p = decode(ThreadProjection.self, emptyProjection)
    p.turnItems = items
    p.visibleTurnItems = items.enumerated().map { ProjectedTurnItem(local: $1, position: $0) }
    p.runs = runs
    return p
}

private func message(_ id: String, ordinal: Int, runId: String? = nil, intent: String = "turn_start") -> TurnItem {
    turnItem("""
        {"id":"\(id)","type":"user_message","ordinal":\(ordinal),"messageId":"m-\(id)","text":"\(id)",
         "inputIntent":"\(intent)","runId":\(runId.map { "\"\($0)\"" } ?? "null")}
        """)
}

private func run(_ id: String, _ status: String, ordinal: Int = 1) -> Run {
    decode(Run.self, """
        {"id":"\(id)","threadId":"thread-1","ordinal":\(ordinal),"status":"\(status)",
         "requestedAt":"2026-01-01T00:00:00.000Z","startedAt":null,"completedAt":null}
        """)
}

private func event(_ type: ThreadEventType, _ payload: ThreadEventPayload, at: String = "2026-01-02T00:00:00.000Z") -> ThreadEvent {
    ThreadEvent(id: "e", type: type, threadId: "thread-1", runId: nil, occurredAt: T3Timestamp(at), payload: payload)
}

private func snapshot(_ p: ThreadProjection, sequence: Int, cursor: String? = nil, more: Bool? = nil, watermark: Int? = nil) -> ThreadStreamItem {
    .snapshot(ThreadDetailSnapshot(
        snapshotSequence: sequence, projection: p, historyCursor: more == nil ? .absent : Tristate(cursor),
        hasMoreHistory: more, latestLocalTurnOrdinal: more == nil ? .absent : Tristate(watermark)))
}

private func ids(_ p: ThreadProjection?) -> [String] { p?.visibleTurnItems.map(\.item.id.rawValue) ?? [] }

/// Ports of orchestrationV2Projection.test.ts, threads-sync.test.ts and threadHistoryMerge.test.ts
/// behavior that the reducer owns.
@Suite struct ThreadReducerTests {
    @Test func skipsReplayedSequencesAndAdvancesOnUnknownEvents() {
        var reducer = ThreadReducer(threadId: "thread-1")
        reducer.apply([snapshot(projection(), sequence: 10), .synchronized])
        #expect(reducer.status == .live && reducer.lastSequence == 10)
        let a = message("a", ordinal: 1)
        var changes = reducer.apply([.event(sequence: 9, event: event(.turnItemUpdated, .turnItem(a)))])
        #expect(changes.isEmpty && ids(reducer.projection).isEmpty)
        changes = reducer.apply([.unknownEvent(sequence: 12, eventType: "thread.teleported")])
        #expect(changes.isEmpty && reducer.lastSequence == 12)
        changes = reducer.apply([.event(sequence: 11, event: event(.turnItemUpdated, .turnItem(a)))])
        #expect(changes.isEmpty)
        reducer.apply([.event(sequence: 13, event: event(.turnItemUpdated, .turnItem(a)))])
        #expect(ids(reducer.projection) == ["a"] && reducer.lastSequence == 13)
        #expect(reducer.projection?.updatedAt == "2026-01-02T00:00:00.000Z")
        #expect(reducer.subscribeInput().afterSequence == 13)
    }

    @Test func ordersLocalRowsByOrdinalThenId() {
        var reducer = ThreadReducer(threadId: "thread-1")
        reducer.apply([snapshot(projection([message("b", ordinal: 2), message("d", ordinal: 4)]), sequence: 1)])
        reducer.apply([
            .event(sequence: 2, event: event(.turnItemUpdated, .turnItem(message("c", ordinal: 3)))),
            .event(sequence: 3, event: event(.turnItemUpdated, .turnItem(message("a", ordinal: 1)))),
            .event(sequence: 4, event: event(.turnItemUpdated, .turnItem(message("e", ordinal: 4)))),
        ])
        #expect(ids(reducer.projection) == ["a", "b", "c", "d", "e"])
        #expect(reducer.projection?.visibleTurnItems.map(\.position) == [0, 1, 2, 3, 4])
    }

    @Test func hidesRolledBackRunsAndCancelledQueuedMessages() {
        var reducer = ThreadReducer(threadId: "thread-1")
        let items = [message("a", ordinal: 1, runId: "r1"), message("q", ordinal: 2, runId: "r2", intent: "queued_turn")]
        reducer.apply([snapshot(projection(items, runs: [run("r1", "completed"), run("r2", "queued", ordinal: 2)]), sequence: 1)])
        reducer.apply([.event(sequence: 2, event: event(.runUpdated, .run(run("r2", "cancelled", ordinal: 2))))])
        #expect(ids(reducer.projection) == ["a"])
        reducer.apply([.event(sequence: 3, event: event(.runUpdated, .run(run("r1", "rolled_back"))))])
        #expect(ids(reducer.projection).isEmpty)
    }

    @Test func dropsOldItemsOutsideAPartialWindow() {
        var reducer = ThreadReducer(threadId: "thread-1")
        reducer.apply([snapshot(projection([message("c", ordinal: 30)]), sequence: 1, cursor: "cur", more: true, watermark: 30)])
        reducer.apply([.event(sequence: 2, event: event(.turnItemUpdated, .turnItem(message("old", ordinal: 10))))])
        #expect(ids(reducer.projection) == ["c"])
        reducer.apply([.event(sequence: 3, event: event(.turnItemUpdated, .turnItem(message("new", ordinal: 40))))])
        #expect(ids(reducer.projection) == ["c", "new"] && reducer.history.latestLocalTurnOrdinal == 40)
    }

    @Test func aSnapshotResetsTheProjectionAndHistory() {
        var reducer = ThreadReducer(threadId: "thread-1")
        reducer.apply([snapshot(projection([message("a", ordinal: 1)]), sequence: 5, cursor: "c1", more: true, watermark: 1)])
        #expect(reducer.history.showsLoadEarlierControl)
        let changes = reducer.apply([snapshot(projection([message("b", ordinal: 2)]), sequence: 3)])
        #expect(changes.reset && ids(reducer.projection) == ["b"] && reducer.lastSequence == 3)
        #expect(reducer.history == ThreadHistoryMeta())
    }

    @Test func threadDeletedStopsApplying() {
        var reducer = ThreadReducer(threadId: "thread-1")
        reducer.apply([snapshot(projection(), sequence: 1)])
        let deleted = decode(AppThread.self, #"{"id":"thread-1","title":"T"}"#)
        let changes = reducer.apply([
            .event(sequence: 2, event: event(.threadDeleted, .thread(deleted))),
            .event(sequence: 3, event: event(.turnItemUpdated, .turnItem(message("a", ordinal: 1)))),
        ])
        #expect(changes.deleted && reducer.status == .deleted && ids(reducer.projection).isEmpty)
    }

    @Test func keepsProviderTurnTokenUsageWhenAnUpdateOmitsIt() {
        var reducer = ThreadReducer(threadId: "thread-1")
        reducer.apply([snapshot(projection(), sequence: 1)])
        reducer.apply([
            .event(sequence: 2, event: event(.providerTurnUpdated, .json(.object(["id": .string("pt"), "tokenUsage": .object(["usedTokens": .number(5)])])))),
            .event(sequence: 3, event: event(.providerTurnUpdated, .json(.object(["id": .string("pt"), "status": .string("completed")])))),
        ])
        #expect(reducer.projection?.providerTurns == [.object(["id": .string("pt"), "status": .string("completed"), "tokenUsage": .object(["usedTokens": .number(5)])])])
    }

    // MARK: History paging (threadHistoryMerge.test.ts)

    @Test func mergesAnOlderPageInFrontAndKeepsLiveRows() {
        var reducer = ThreadReducer(threadId: "thread-1")
        let live = message("c", ordinal: 3)
        reducer.apply([snapshot(projection([live]), sequence: 1, cursor: "c1", more: true, watermark: 3)])
        let request = reducer.beginLoadEarlier()
        #expect(request?.cursor == "c1" && reducer.history.loading)
        #expect(reducer.beginLoadEarlier() == nil)
        let stale = message("c", ordinal: 3)
        let page = ThreadHistoryPage(
            snapshotSequence: 1,
            items: [message("a", ordinal: 1), message("b", ordinal: 2), message("a", ordinal: 1), stale].map { ProjectedTurnItem(local: $0) },
            nextCursor: "c0", hasMoreHistory: true)
        reducer.applyHistoryPage(page, requestCursor: "c1")
        #expect(ids(reducer.projection) == ["a", "b", "c"])
        #expect(reducer.projection?.visibleTurnItems.map(\.position) == [0, 1, 2])
        #expect(reducer.projection?.turnItems.map(\.id.rawValue) == ["c", "a", "b"])
        #expect(reducer.history.historyCursor == "c0" && reducer.history.expanded && !reducer.history.loading)
        #expect(reducer.history.latestLocalTurnOrdinal == 3)
    }

    @Test func ignoresAPageForAnOldCursor() {
        var reducer = ThreadReducer(threadId: "thread-1")
        reducer.apply([snapshot(projection([message("c", ordinal: 3)]), sequence: 1, cursor: "c1", more: true, watermark: 3)])
        _ = reducer.beginLoadEarlier()
        let page = ThreadHistoryPage(snapshotSequence: 1, items: [ProjectedTurnItem(local: message("a", ordinal: 1))], nextCursor: nil, hasMoreHistory: false)
        #expect(reducer.applyHistoryPage(page, requestCursor: "other").isEmpty)
        reducer.failHistoryLoad(requestCursor: "c1", message: "Could not load earlier turns.")
        #expect(reducer.history.error != nil && !reducer.history.loading && reducer.history.showsLoadEarlierControl)
    }

    /// Stress regression (seed 2 of the bounded run): a page request cancelled when the app moved the
    /// thread to a new connection left `loading` set, so the control spun and no older page ever
    /// loaded again. Like T3's interrupt path (threadHistoryMerge.ts:38-50) the cancel clears it
    /// without an error, and only for the cursor it started from.
    @Test func aCancelledPageRequestFreesTheControl() {
        var reducer = ThreadReducer(threadId: "thread-1")
        reducer.apply([snapshot(projection([message("c", ordinal: 3)]), sequence: 1, cursor: "c1", more: true, watermark: 3)])
        let request = reducer.beginLoadEarlier()
        #expect(request != nil && reducer.beginLoadEarlier() == nil)
        #expect(reducer.cancelHistoryLoad(requestCursor: "stale").isEmpty)
        #expect(reducer.history.loading)
        #expect(reducer.cancelHistoryLoad(requestCursor: "c1").historyChanged)
        #expect(!reducer.history.loading && reducer.history.error == nil)
        #expect(reducer.beginLoadEarlier()?.cursor == "c1")
    }

    /// Stress regression: an optimistic prompt whose row arrived without its message (a bounded
    /// snapshot or an older page carries rows but not every message, and a message event can be
    /// lost to a reconnect) stayed pending and showed twice. T3 counts the row as acknowledged.
    @Test func aUserRowAcknowledgesItsOptimisticMessage() {
        var p = projection([message("a", ordinal: 1)])
        #expect(TimelineEntries.acknowledgedUserMessageIds(p) == ["m-a"])
        p.visibleTurnItems = []
        #expect(TimelineEntries.acknowledgedUserMessageIds(p).isEmpty)
        #expect(TimelineEntries.acknowledgedUserMessageIds(nil).isEmpty)
    }

    @Test func hiddenLiveItemsStayHiddenWhenAPageRepeatsThem() {
        let hidden = message("q", ordinal: 1, runId: "r1", intent: "queued_turn")
        var p = projection([message("c", ordinal: 3)], runs: [run("r1", "cancelled")])
        p.turnItems.append(hidden)
        let merged = ThreadReduction.mergeOlderHistory(p, [ProjectedTurnItem(local: hidden)])
        #expect(ids(merged) == ["c"])
    }

    // MARK: Store

    @Test func storeCoalescesChangesUntilTaken() async {
        let calls = Counter()
        let store = ThreadStore(threadId: "thread-1") { calls.increment() }
        await store.apply([snapshot(projection(), sequence: 1)])
        await store.apply([.event(sequence: 2, event: event(.turnItemUpdated, .turnItem(message("a", ordinal: 1)))), .synchronized])
        #expect(calls.value == 1)
        let update = await store.takeUpdate()
        #expect(update?.changes.reset == true && update?.changes.synchronized == true && update?.status == .live)
        #expect(ids(update?.projection) == ["a"] && update?.lastSequence == 2)
        #expect(await store.takeUpdate() == nil)
        let input = await store.subscribeInput()
        #expect(input.afterSequence == 2 && input.acceptBoundedSnapshot == true)
    }

    /// The window's first change says whether it only grew a streaming text, so the session waits for
    /// T3's pair only while text streams, never for the change after a stream.
    @Test func storeReportsStreamingFirstChange() async {
        final class Flags: @unchecked Sendable {
            let lock = NSLock()
            var values: [Bool] = []
            func add(_ v: Bool) { lock.withLock { values.append(v) } }
        }
        let flags = Flags()
        let answer = { (text: String, streaming: Bool) in
            turnItem("""
                {"id":"a","type":"assistant_message","ordinal":2,"messageId":"m-a","text":"\(text)","streaming":\(streaming)}
                """)
        }
        let store = ThreadStore(threadId: "thread-1", onFirstChange: { flags.add($0) })
        await store.apply([snapshot(projection([message("q", ordinal: 1), answer("He", true)]), sequence: 1), .synchronized])
        _ = await store.takeUpdate()
        await store.apply([.event(sequence: 2, event: event(.turnItemUpdated, .turnItem(answer("Hello", true))))])
        _ = await store.takeUpdate()
        await store.apply([.event(sequence: 3, event: event(.turnItemUpdated, .turnItem(answer("Hello", false))))])
        #expect(flags.values == [false, true, false])
    }

    // MARK: Recorded streams

    @Test func replayingEventsReachesTheServersOwnSnapshot() throws {
        // 03-turn2 subscribed twice: the first stream replays every event from an empty thread,
        // the second resumes too late and gets a bounded snapshot at the same sequence.
        let streams = try recordedThreadStreams("03-turn2.jsonl")
        #expect(streams.count == 2)
        let replayed = replay(streams[0])
        let snapshotted = replay(streams[1])
        #expect(replayed.lastSequence == 198 && snapshotted.lastSequence == 198)
        #expect(replayed.status == .live && snapshotted.status == .live)
        #expect(replayed.projection?.visibleTurnItems.map(\.item) == snapshotted.projection?.visibleTurnItems.map(\.item))
        #expect(replayed.projection?.runs.map(\.status) == snapshotted.projection?.runs.map(\.status))
        #expect(Set(replayed.projection?.checkpoints.map(\.id) ?? []) == Set(snapshotted.projection?.checkpoints.map(\.id) ?? []))
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
