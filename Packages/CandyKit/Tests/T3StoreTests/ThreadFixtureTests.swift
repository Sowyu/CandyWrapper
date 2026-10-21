import Foundation
import T3Protocol
import Testing
@testable import T3Store

private func threadRows(_ name: String, titled prefix: String, _ edit: (inout TimelineRowsInput, ThreadProjection) -> Void = { _, _ in }) throws -> [TimelineRow] {
    let stream = try #require(try recordedThreadStreams(name).last { replay($0).projection?.thread.title.hasPrefix(prefix) == true })
    let projection = try #require(replay(stream).projection)
    var input = TimelineRowsInput(projection: projection)
    edit(&input, projection)
    return TimelineRows.derive(input)
}

private func foldLabels(_ rows: [TimelineRow]) -> [String] {
    rows.compactMap { if case .turnFold(_, let label, _) = $0.kind { return label }; return nil }
}

/// Replays every recorded `subscribeThread` stream and derives its timeline.
@Suite struct ThreadFixtureTests {
    @Test(arguments: [("02-turn.jsonl", 1), ("03-turn2.jsonl", 2), ("04-threads.jsonl", 14), ("06-requests.jsonl", 2), ("07-queue.jsonl", 1)])
    func everyRecordedThreadDerivesRows(_ name: String, _ count: Int) throws {
        let streams = try recordedThreadStreams(name)
        #expect(streams.count == count)
        for stream in streams {
            let reducer = replay(stream)
            let projection = try #require(reducer.projection, "\(stream.threadId)")
            #expect(reducer.status == .live)
            let rows = TimelineRows.derive(TimelineRowsInput(projection: projection))
            #expect(!rows.isEmpty)
            #expect(Set(rows.map(\.id)).count == rows.count, "row ids must be unique")
            // Settled threads never produce live rows.
            #expect(!rows.contains { ["working", "thinking", "work-live"].contains(describe($0)) })
            // Expanding every fold and group reveals every derived entry without breaking ids.
            var all = TimelineRowsInput(projection: projection)
            all.expandedRunIds = Set(projection.runs.map(\.id))
            all.expandedWorkGroupIds = Set(all.entries.map { "work-group:\($0.id)" })
            let expanded = TimelineRows.derive(all)
            #expect(Set(expanded.map(\.id)).count == expanded.count)
            #expect(expanded.count >= rows.count)
        }
    }

    @Test func countFilesShowsAFoldedTurnAndAnInterruptedOne() throws {
        let rows = try threadRows("04-threads.jsonl", titled: "Count files")
        #expect(rows.map(describe) == ["user", "turn-fold", "assistant", "user", "event(run_interrupt_result)"])
        #expect(foldLabels(rows) == ["Worked for 2.1s"])
        let expanded = try threadRows("04-threads.jsonl", titled: "Count files") { input, p in input.expandedRunIds = Set(p.runs.map(\.id)) }
        guard case .work(_, false, let label) = expanded[2].kind else { Issue.record("expected the command row"); return }
        #expect(label == "ls -1 | wc -l")
    }

    @Test func addNotesFoldsThreeTurnsAndCarriesTheChangedFiles() throws {
        let rows = try threadRows("03-turn2.jsonl", titled: "Add notes")
        #expect(rows.map(describe) == ["user", "turn-fold", "assistant", "user", "turn-fold", "assistant", "user", "turn-fold", "assistant"])
        #expect(foldLabels(rows) == ["Worked for 12s", "Worked for 3.6s", "Worked for 13s"])
        guard case .message(_, _, true, true, false, let summary?) = rows[2].kind else { Issue.record("expected the first answer"); return }
        #expect(summary.files.map(\.path).sorted() == ["hello.py", "notes.md"] && summary.checkpointTurnCount == 1)

        let expanded = try threadRows("03-turn2.jsonl", titled: "Add notes") { input, p in input.expandedRunIds = [p.runs.min { $0.ordinal < $1.ordinal }!.id] }
        #expect(expanded.map(describe).prefix(4) == ["user", "turn-fold", "work-toggle", "assistant"])
        guard case .workToggle(let toggle) = expanded[2].kind else { Issue.record("expected a group"); return }
        #expect(toggle.summary == "Ran 1 command, changed 2 files, and performed 3 other actions")
        #expect(toggle.summaryKind == "mixed" && toggle.hiddenCount == 8 && !toggle.hasFailure)
    }

    @Test func aBackgroundNotificationStartsANewResponse() throws {
        let rows = try threadRows("04-threads.jsonl", titled: "Run exactly this shell command")
        #expect(rows.map(describe) == ["user", "turn-fold", "assistant", "work", "assistant"])
        guard case .work(let grouped, _, _) = rows[3].kind else { Issue.record("expected the notification"); return }
        #expect(grouped.first?.itemType == .notification && grouped.first?.label == #"Command "Sleep 150 seconds in background" finished"#)
    }

    @Test func workspacePreparationNeverShows() throws {
        let rows = try threadRows("04-threads.jsonl", titled: "Reply with markdown only")
        #expect(rows.map(describe) == ["user", "assistant"])
    }

    @Test func anUnansweredRunFoldsWithoutAnAnswer() throws {
        #expect(try threadRows("04-threads.jsonl", titled: "Create a file named approval-demo").map(describe) == ["user", "turn-fold"])
    }

    /// 07-queue: a queued message promoted to steer, then a `deliveryIntent:"steer"` dispatch, both
    /// inside one running turn. T3 places a steer by its turn item ordinal (session-logic.ts:592-809),
    /// so it sits inside its run after the work that came before it, and it never starts a new
    /// response (MessagesTimeline.logic.ts:879-886). Checked after every Chunk, live and settled.
    @Test func steeredMessagesShowInsideTheirTurn() throws {
        let stream = try #require(try recordedThreadStreams("07-queue.jsonl").first)
        var reducer = ThreadReducer(threadId: stream.threadId)
        func userRows(_ rows: [TimelineRow]) -> [(index: Int, intent: InputIntent?)] {
            rows.enumerated().compactMap { i, row in
                if case .message(let m, _, _, _, _, _) = row.kind, m.role == .user { return (i, m.inputIntent) }
                return nil
            }
        }
        var sawLiveSteer = false
        for chunk in stream.chunks {
            reducer.apply(chunk)
            let projection = try #require(reducer.projection)
            let steers = projection.turnItems.filter {
                $0.type == .userMessage && ($0.inputIntent == .steer || $0.inputIntent == .promotedQueuedToSteer)
            }
            let rows = TimelineRows.derive(TimelineRowsInput(projection: projection))
            let users = userRows(rows)
            // Every steer the server has sent has its own row, in server order after the prompt.
            #expect(users.count == 1 + steers.count)
            #expect(users.map(\.intent) == [.turnStart] + steers.map(\.inputIntent))
            if TimelineRowsInput(projection: projection).isWorking, let last = users.last, steers.count == 2 {
                sawLiveSteer = true
                // Live: the working header stays under the first prompt, and the steer sits above
                // the activity that follows it.
                #expect(rows.firstIndex { $0.id == "working-indicator-row" } == 1)
                #expect(last.index < rows.count - 1)
            }
        }
        #expect(sawLiveSteer)
        let rows = TimelineRows.derive(TimelineRowsInput(projection: try #require(reducer.projection)))
        // Settled: the run folds behind the first prompt and both steers stay out of the fold. Since 3473 the work
        // after back-to-back steers folds under its own row after the last of them (MessagesTimeline.logic.ts:1064-1075).
        #expect(rows.map(describe) == ["user", "turn-fold", "user", "user", "turn-fold", "assistant"])
        #expect(userRows(rows).map(\.intent) == [.turnStart, .promotedQueuedToSteer, .steer])
        guard case .message(let steer, _, _, _, _, _) = rows[3].kind else { Issue.record("expected the steer"); return }
        #expect(steer.text == "Then also say: steered")
    }
}
