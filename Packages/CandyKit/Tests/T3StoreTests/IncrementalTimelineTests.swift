import Foundation
import T3Protocol
import Testing
@testable import T3Store

/// The incremental entry pass and the streaming row patch must give exactly what a full pass
/// gives. Every recorded thread stream is replayed one item at a time, the finest update rate.
@Suite struct IncrementalTimelineTests {
    static let transcripts = ["01-basic.jsonl", "02-turn.jsonl", "03-turn2.jsonl", "04-threads.jsonl",
                              "05-composer.jsonl", "06-requests.jsonl", "07-queue.jsonl"]

    @Test func replayMatchesAFullPassAtEveryStep() throws {
        var steps = 0, patches = 0, inPlace = 0
        for name in Self.transcripts {
            for stream in try recordedThreadStreams(name) {
                var reducer = ThreadReducer(threadId: stream.threadId)
                var memo = TimelineRowsInput.Memo()
                var derived: TimelineRows.Derived?
                for item in stream.chunks.joined() {
                    guard !reducer.apply([item]).isEmpty, let p = reducer.projection else { continue }
                    steps += 1
                    let (input, changed) = TimelineRowsInput.derive(projection: p, memo: &memo)
                    let full = TimelineRowsInput(projection: p)
                    #expect(input.entries == full.entries, "\(name) step \(steps): entries differ")
                    #expect(input.sameContext(full))
                    let expected = TimelineRows.derive(input)
                    if let changed {
                        inPlace += 1
                        // In-place changes are exactly the entries that differ.
                        if let old = derived?.input.entries, old.count == input.entries.count {
                            let differing = input.entries.indices.filter { input.entries[$0] != old[$0] }
                            #expect(changed.sorted() == differing, "\(name) step \(steps): changed \(changed) vs \(differing)")
                        }
                    }
                    if let previous = derived, let changed,
                       let (patched, rows) = TimelineRows.patchingStreamingText(previous, input: input, changedEntries: changed) {
                        patches += 1
                        #expect(patched.rows == expected, "\(name) step \(steps): patched rows differ")
                        for i in rows { #expect(previous.rows[i] != patched.rows[i]) }
                        derived = patched
                    } else {
                        derived = TimelineRows.Derived(input)
                        #expect(derived!.rows == expected)
                    }
                }
            }
        }
        #expect(steps > 100)
        #expect(inPlace > 0)
        #expect(patches > 0, "no streaming text update took the patch path")
    }

    /// A history page puts older rows in front: the memo finds rows by id and reports a new shape.
    @Test func olderRowsInFrontRebuildTheShape() throws {
        let streams = try recordedThreadStreams("04-threads.jsonl")
        let p = try #require(streams.map { replay($0).projection }.compactMap { $0 }.max { $0.visibleTurnItems.count < $1.visibleTurnItems.count })
        #expect(p.visibleTurnItems.count > 4)
        var window = p
        window.visibleTurnItems = Array(p.visibleTurnItems.suffix(p.visibleTurnItems.count / 2))
        var memo = TimelineRowsInput.Memo()
        _ = TimelineRowsInput.derive(projection: window, memo: &memo)
        let (input, changed) = TimelineRowsInput.derive(projection: p, memo: &memo)
        #expect(changed == nil)
        #expect(input.entries == TimelineRowsInput(projection: p).entries)
    }

    /// Only text of a streaming answer is patched; a tool status change needs the full pass.
    @Test func patchIsOnlyForStreamingText() throws {
        let streams = try recordedThreadStreams("02-turn.jsonl")
        let p = try #require(streams.compactMap { replay($0).projection }.first { $0.visibleTurnItems.contains { $0.item.type == .commandExecution } })
        let tool = try #require(p.visibleTurnItems.firstIndex { $0.item.type == .commandExecution })
        var memo = TimelineRowsInput.Memo()
        let before = TimelineRows.Derived(TimelineRowsInput.derive(projection: p, memo: &memo).input)
        var q = p
        guard case .object(var raw) = q.visibleTurnItems[tool].item.raw else { Issue.record("no raw"); return }
        raw["status"] = .string("running")
        q.visibleTurnItems[tool].item = try TurnItem(json: .object(raw))
        let (input, changed) = TimelineRowsInput.derive(projection: q, memo: &memo)
        #expect(changed?.count == 1)
        #expect(TimelineRows.patchingStreamingText(before, input: input, changedEntries: changed ?? []) == nil)
    }
}
