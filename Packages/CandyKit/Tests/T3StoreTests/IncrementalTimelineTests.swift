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

/// A history page derives only its own rows and the old rows it reaches (`Derived.prepend`); the
/// result must equal a full pass after every page. Every recorded thread and a long thread built
/// from copies of the largest one are paged in from their newest rows, with page sizes that split
/// turns, work groups and attempts at many offsets, settled, running and with every fold open.
@Suite struct HistoryPagingTests {
    /// Every recorded thread's final projection, and 12 copies of the largest one.
    static func threads() throws -> [ThreadProjection] {
        var all: [ThreadProjection] = []
        for name in IncrementalTimelineTests.transcripts {
            for stream in try recordedThreadStreams(name) {
                if let p = replay(stream).projection, p.visibleTurnItems.count > 2 { all.append(p) }
            }
        }
        let largest = try #require(all.max { $0.visibleTurnItems.count < $1.visibleTurnItems.count })
        all.append(try copies(of: largest, 12))
        all.append(try copies(of: largest, 12, tangled: true))
        return all
    }

    /// `count` copies of a thread's turns one after another: ids get a per-copy suffix and ordinals
    /// a per-copy offset, as in the perf benchmarks' huge thread. `tangled` moves every third
    /// non-user row into the previous copy's run, so runs reach across prompts, and leaves
    /// reasoning running, so a row before a cut must settle it.
    static func copies(of p: ThreadProjection, _ count: Int, tangled: Bool = false) throws -> ThreadProjection {
        func copy(_ value: JSONValue, _ k: Int, key: String? = nil) -> JSONValue {
            func isId(_ key: String) -> Bool {
                (key == "id" || key.hasSuffix("Id") || key.hasSuffix("Ids"))
                    && !["threadId", "sourceThreadId", "projectId", "providerInstanceId"].contains(key)
            }
            switch value {
            case .object(let o): return .object(Dictionary(uniqueKeysWithValues: o.map { ($0.key, copy($0.value, k, key: $0.key)) }))
            case .array(let a): return .array(a.map { copy($0, k, key: key) })
            case .string(let s) where key.map(isId) == true: return .string(s + "~\(k)")
            case .number(let n) where key == "ordinal": return .number(n + Double(k) * 100_000_000)
            default: return value
            }
        }
        let json = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(p))
        guard case .object(var o) = json else { throw CancellationError() }
        for key in ["runs", "attempts", "nodes", "checkpoints", "runtimeRequests", "providerTurns", "visibleTurnItems", "messages", "turnItems", "plans"] {
            guard case .array(let items)? = o[key] else { continue }
            o[key] = .array((0..<count).flatMap { k in items.map { copy($0, k) } })
        }
        if tangled, case .array(let rows)? = o["visibleTurnItems"] {
            o["visibleTurnItems"] = .array(rows.enumerated().map { i, row in
                guard case .object(var r) = row, case .object(var item)? = r["item"], item["type"] != .string("user_message")
                else { return row }
                if i % 3 == 1, (i / max(1, rows.count / count)) % 2 == 0, case .string(let run)? = item["runId"], let tilde = run.lastIndex(of: "~"),
                   let k = Int(run[run.index(after: tilde)...]), k > 0 {
                    item["runId"] = .string(run[..<tilde] + "~\(k - 1)")
                }
                if item["type"] == .string("reasoning") { item["status"] = .string("running") }
                r["item"] = .object(item)
                return .object(r)
            })
        }
        var result = try JSONValue.object(o).decode(as: ThreadProjection.self)
        result.visibleTurnItems = result.visibleTurnItems.enumerated().map { i, row in var row = row; row.position = i; return row }
        return result
    }

    /// Pages `full` in from its newest `page` rows and checks every step against a full pass.
    /// Returns how many pages took the splice.
    static func page(_ full: ThreadProjection, by page: Int, _ edit: (inout TimelineRowsInput) -> Void) -> (pages: Int, spliced: Int) {
        let all = full.visibleTurnItems
        var p = full
        p.visibleTurnItems = all.suffix(page).enumerated().map { i, row in var row = row; row.position = i; return row }
        let windowIds = Set(p.visibleTurnItems.map(\.sourceItemId))
        p.turnItems = p.turnItems.filter { windowIds.contains($0.id) }
        var memo = TimelineRowsInput.Memo()
        var input = TimelineRowsInput.derive(projection: p, memo: &memo).input
        edit(&input)
        var derived = TimelineRows.Derived(input)
        var loaded = p.visibleTurnItems.count
        var pages = 0, spliced = 0
        while loaded < all.count {
            let older = Array(all[max(0, all.count - loaded - page)..<(all.count - loaded)])
            loaded += older.count
            p = ThreadReduction.mergeOlderHistory(p, older)
            pages += 1
            input = TimelineRowsInput.derive(projection: p, memo: &memo).input
            edit(&input)
            var expected = TimelineRowsInput(projection: p)
            edit(&expected)
            #expect(input.entries == expected.entries, "page \(pages) of \(page): entries differ")
            let before = derived.rows
            if let count = memo.prepended, let (replaced, inserted) = derived.prepend(input, count: count) {
                spliced += 1
                #expect(Array(derived.rows[inserted...]) == Array(before[replaced...]))
            } else {
                derived = TimelineRows.Derived(input)
            }
            let rows = TimelineRows.derive(expected)
            if derived.rows != rows {
                let at = rows.indices.first { $0 >= derived.rows.count || derived.rows[$0] != rows[$0] } ?? rows.count
                Issue.record("page \(pages) of \(page): \(derived.rows.count) rows against \(rows.count), first difference at \(at)")
                return (pages, spliced)
            }
            // The message index the streaming patch uses stays right.
            for (i, row) in rows.enumerated() {
                if let m = row.message, !derived.messageRows(m.id.rawValue).contains(i) {
                    Issue.record("page \(pages) of \(page): message row \(i) not indexed")
                }
            }
        }
        return (pages, spliced)
    }

    @Test(arguments: [1, 2, 3, 5, 8, 19, 40])
    func pagesMatchAFullPass(_ size: Int) throws {
        var pages = 0, spliced = 0
        for p in try Self.threads() {
            let runIds = Set(p.runs.map(\.id)), attemptIds = Set(p.attempts.map(\.id))
            let groupIds = Set(TimelineRowsInput(projection: p).entries.map { TimelineRows.workGroupId($0.id) })
            let variants: [(inout TimelineRowsInput) -> Void] = [
                { _ in },
                // The newest run still works.
                { input in
                    guard let run = p.runs.max(by: { $0.ordinal < $1.ordinal }) else { return }
                    input.latestRun = TimelineLatestRun(runId: run.id, status: .running, requestedAt: run.requestedAt, startedAt: run.startedAt)
                    input.runningRunId = run.id
                    input.isWorking = true
                    input.activeTurnStartedAt = run.startedAt
                },
                // Every fold and group open.
                { input in
                    input.expandedRunIds = runIds
                    input.expandedAttemptIds = attemptIds
                    input.expandedWorkGroupIds = groupIds
                },
            ]
            for variant in variants {
                let (n, s) = Self.page(p, by: size, variant)
                pages += n
                spliced += s
            }
        }
        #expect(pages > 0)
        // Most pages end inside the old rows' first turn, so most take the splice.
        #expect(spliced * 2 > pages, "\(spliced) of \(pages) pages spliced")
    }
}
