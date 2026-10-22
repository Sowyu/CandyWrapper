import Foundation
import Testing
import T3Protocol
@testable import T3Store
@testable import Features

/// One seeded stress run of the thread pipeline: a generated thread streams from a fake server
/// through the reducer and the row pipeline while the connection drops, resumes with duplicated
/// replays or fresh snapshots, history pages arrive between live deltas, the app restarts from its
/// disk cache, the user opens folds and sends prompts. Every step checks `StressInvariants`, and
/// the rows the pipeline patched must equal a derive from scratch. At the end the client catches
/// up and must hold the server's rows.
final class ThreadStressRun {
    struct Options: Sendable {
        var runs = 6
        var maxSteps = 8
        /// Deliver some events out of order (they are dropped by sequence, as in T3), then end on a
        /// fresh snapshot.
        var outOfOrder = false
        var bounded = true
        var cache = true
        var mode: StressThreadGenerator.Mode = .normal
    }

    let seed: UInt64
    let options: Options
    var rng: StressRNG
    let server: StressServer
    let features: Set<String>
    var client: ThreadReducer
    var connected = false
    var inbox: [ThreadStreamItem] = []
    var historyRequest: ThreadHistoryRequest?
    var pipeline = TimelinePipeline()
    var shown: [TimelineRow] = []
    var expandedRuns = Set<RunId>()
    var expandedAttempts = Set<RunAttemptId>()
    var expandedGroups = Set<String>()
    var optimistic: [ChatMessage] = []
    var problems: [String] = []
    var log: [String] = []
    var steps = 0
    /// Milliseconds of reducer plus row work per step that only patched rows (no snapshot, no page).
    var normalStepMs: [Double] = []
    var slowest: (ms: Double, what: String) = (0, "")
    let cache: ThreadCache
    let cacheKey: ThreadCache.Key
    var cacheDirectory: URL
    var freshSinceDisorder = true
    /// The cached state was saved after an out-of-order delivery dropped an event.
    var cacheDisordered = false
    /// The projection changed since the pipeline last ran.
    var dirty = false
    var onlyStreamingText = true
    /// Every projection the pipeline saw, with whether only streaming text grew since the one
    /// before, for the panel replay.
    var observed: [(ThreadProjection?, Bool)] = []

    init(seed: UInt64, options: Options) throws {
        self.seed = seed
        self.options = options
        rng = StressRNG(seed: seed ^ 0xC0FFEE)
        // Thread size varies with the seed: from one short run to twice the configured length.
        var generator = StressThreadGenerator(seed: seed, mode: options.mode, runCount: max(1, options.runs / 2 + Int(seed % UInt64(options.runs + 1))),
                                              maxSteps: max(2, options.maxSteps / 2 + Int(seed % 7)))
        let script = generator.generate()
        features = script.features
        server = try StressServer(script: script)
        server.windowTurns = rng.int(1...3)
        server.pageTurns = rng.int(1...2)
        client = ThreadReducer(threadId: server.threadId)
        cacheDirectory = FileManager.default.temporaryDirectory.appending(path: "cw-stress-\(seed)-\(UUID().uuidString)")
        cache = ThreadCache(directory: cacheDirectory, firstWriteDelay: .zero, writeInterval: .zero)
        cacheKey = ThreadCache.Key(environmentId: "env", threadId: server.threadId)
    }

    deinit { try? FileManager.default.removeItem(at: cacheDirectory) }

    func note(_ line: String) {
        log.append(line)
        if log.count > 60 { log.removeFirst(log.count - 60) }
    }

    // MARK: Checks

    func fail(_ list: [String], _ what: String) {
        guard !list.isEmpty else { return }
        problems += list.prefix(4).map { "seed \(seed) step \(steps) \(what): \($0)" }
    }

    /// Runs the pipeline the way `ThreadViewModel.derive` does and checks the result.
    func check(projectionChanged: Bool, timed start: ContinuousClock.Instant? = nil, normal: Bool = false, mayDefer: Bool = false) {
        steps += 1
        guard problems.isEmpty else { return }
        // The view model coalesces: updates that land while a row pass runs, or inside one pacer
        // window, reach the pipeline as one request.
        dirty = dirty || projectionChanged
        if mayDefer, rng.chance(0.3) { return }
        let projectionChanged = dirty
        dirty = false
        let projection = client.projection
        if let projection, projectionChanged { observed.append((projection, onlyStreamingText)) }
        onlyStreamingText = true
        // The same filter as `ThreadViewModel.derive`.
        let confirmed = TimelineEntries.acknowledgedUserMessageIds(projection)
        let pending = optimistic.filter { $0.inputIntent != .queuedTurn && !confirmed.contains($0.id) }
        let request = TimelinePipeline.Request(
            projection: projection, projectionChanged: projectionChanged, expandedRunIds: expandedRuns,
            expandedAttemptIds: expandedAttempts, expandedWorkGroupIds: expandedGroups, pending: pending)
        let result = pipeline.run(request)
        if let start, normal {
            let ms = OpenTiming.ms(ContinuousClock.now - start)
            normalStepMs.append(ms)
            if ms > slowest.ms { slowest = (ms, "\(log.last ?? "") at \(client.projection?.visibleTurnItems.count ?? 0) rows") }
        }
        if let result {
            fail(StressInvariants.change(result.change, old: shown, new: result.rows), "change")
            shown = result.rows
        }
        guard let projection else { return }
        fail(StressInvariants.projection(projection, partial: client.history.isPartial), "projection")
        var input = TimelineRowsInput(projection: projection)
        input.expandedRunIds = expandedRuns
        input.expandedAttemptIds = expandedAttempts
        input.expandedWorkGroupIds = expandedGroups
        input.entries += pending.map { TimelineEntry.message($0.id.rawValue, $0) }
        if let last = pending.last, ComposerCompaction.isCompactCommand(last.text, attachments: last.attachments.count) {
            input.isWorking = true
            input.isCompacting = true
        }
        let fresh = TimelineRows.derive(input)
        if fresh != shown {
            let firstDiff = (0..<min(fresh.count, shown.count)).first { fresh[$0] != shown[$0] } ?? min(fresh.count, shown.count)
            fail(["incremental rows differ from a fresh derive at row \(firstDiff): "
                  + "got \(shown.dropFirst(firstDiff).prefix(2).map(\.id)), want \(fresh.dropFirst(firstDiff).prefix(2).map(\.id))"], "pipeline")
        }
        fail(StressInvariants.rows(fresh, input: input), "rows")
        if !problems.isEmpty, ProcessInfo.processInfo.environment["CW_STRESS_VERBOSE"] != nil {
            problems.append("rows: " + fresh.map { "\(StressInvariants.kind($0)):\($0.id)" }.joined(separator: ", "))
            problems.append("pending: \(pending.map(\.id.rawValue)), messages: \(projection.messages.map(\.id.rawValue))")
        }
        fail(StressInvariants.everythingOnce(input, projection: projection), "all open")
    }

    // MARK: Actions

    func apply(_ items: [ThreadStreamItem], _ what: String) {
        guard !items.isEmpty else { return }
        note("\(what): \(items.map(Self.describe))")
        let start = ContinuousClock.now
        let changes = client.apply(items)
        if changes.projectionChanged { onlyStreamingText = onlyStreamingText && changes.onlyStreamingText && !changes.reset }
        check(projectionChanged: changes.projectionChanged, timed: start, normal: !changes.reset && !changes.historyChanged, mayDefer: true)
    }

    static func describe(_ item: ThreadStreamItem) -> String {
        switch item {
        case .synchronized: "sync"
        case .snapshot(let s): "snapshot@\(s.snapshotSequence)(\(s.projection.visibleTurnItems.count) rows\(s.hasMoreHistory == true ? ", more" : ""))"
        case .event(let seq, let e):
            if case .turnItem(let item) = e.payload { "\(seq):\(item.type.rawValue)/\(item.status.rawValue)" } else { "\(seq):\(e.type.rawValue)" }
        default: "other"
        }
    }

    func publish() {
        // The user sends a prompt a moment before the server confirms it.
        for index in server.published..<min(server.items.count, server.published + 6) {
            guard let send = server.sends[index], !optimistic.contains(where: { $0.id.rawValue == send.id }), rng.chance(0.5) else { continue }
            optimistic.append(ChatMessage(
                id: MessageId(send.id), role: .user, text: send.text, createdAt: "2026-10-12T00:00:00.000Z",
                inputIntent: send.intent.map { InputIntent(rawValue: $0) }))
            note("optimistic \(send.id)")
            check(projectionChanged: false)
        }
        let batch = server.publish(rng.int(1...4))
        guard connected else { return }
        inbox += batch
        if rng.chance(0.08), let old = server.items[..<server.published].randomElement(using: &rng) {
            inbox.append(old)  // a replay the server sent twice
        }
        if options.outOfOrder, inbox.count >= 2, rng.chance(0.15) {
            let i = rng.int(0...inbox.count - 2)
            inbox.swapAt(i, i + 1)
            freshSinceDisorder = false
        }
    }

    func deliver() {
        guard connected, !inbox.isEmpty else { return }
        let n = min(inbox.count, rng.int(1...5))
        let chunk = Array(inbox.prefix(n))
        inbox.removeFirst(n)
        apply(chunk, "chunk")
    }

    func disconnect() {
        guard connected else { return }
        connected = false
        note("disconnect, \(inbox.count) in flight lost")
        inbox = []
    }

    func connect(forceSnapshot: Bool = false, full: Bool = false) {
        disconnect()
        connected = true
        let input = client.subscribeInput()
        if forceSnapshot || input.afterSequence == nil || rng.chance(0.15) {
            let snapshot = server.snapshot(bounded: options.bounded && !full, compact: rng.chance(0.5))
            freshSinceDisorder = true
            apply([.snapshot(snapshot)], "subscribe, snapshot")
        } else {
            var replay = server.replay(after: input.afterSequence!)
            // An overlapping replay: the server resends a few events the client has.
            let before = server.replay(after: max(server.base, input.afterSequence! - rng.int(0...4)))
            if rng.chance(0.3) { replay = Array(before.prefix(before.count - replay.count)) + replay }
            inbox = replay
            note("subscribe after \(input.afterSequence!), replay \(replay.count)")
        }
        inbox.append(.synchronized)
    }

    func history() {
        if let request = historyRequest {
            historyRequest = nil
            if rng.chance(0.15) {
                note("history page failed")
                let changes = client.failHistoryLoad(requestCursor: request.cursor, message: "Could not load earlier turns.")
                check(projectionChanged: changes.projectionChanged)
            } else {
                let page = server.historyPage(cursor: request.cursor)
                note("history page \(page.items.count) rows, more \(page.hasMoreHistory)")
                let changes = client.applyHistoryPage(page, requestCursor: request.cursor)
                check(projectionChanged: changes.projectionChanged)
            }
        } else if let request = client.beginLoadEarlier() {
            note("load earlier \(request.cursor)")
            historyRequest = request
            check(projectionChanged: false)
        }
    }

    /// The app replaced its shell session (`ThreadSession.attach`): the page request in flight is
    /// cancelled, then the stream resumes on the new session.
    func replaceSession() {
        if let request = historyRequest {
            historyRequest = nil
            note("history request cancelled")
            let changes = client.cancelHistoryLoad(requestCursor: request.cursor)
            check(projectionChanged: changes.projectionChanged)
        }
        connect()
    }

    func toggle() {
        var choices: [() -> Void] = []
        for row in shown {
            switch row.kind {
            case .turnFold(let run, _, _): choices.append { self.expandedRuns.formSymmetricDifference([run]) }
            case .attemptFold(_, let attempt, _, _): choices.append { self.expandedAttempts.formSymmetricDifference([attempt]) }
            case .workToggle(let t): choices.append { self.expandedGroups.formSymmetricDifference([t.groupId]) }
            case .workLive(_, _, let id, _, _, _), .thinking(let id?, _, _): choices.append { self.expandedGroups.formSymmetricDifference([id]) }
            default: break
            }
        }
        guard !choices.isEmpty else { return }
        rng.pick(choices)()
        note("toggle")
        check(projectionChanged: false)
    }

    func saveCache() async {
        guard options.cache, let projection = client.projection, let sequence = client.lastSequence,
              ThreadCache.shouldPersist(projection, history: client.history) else { return }
        var history = client.history
        history.loading = false
        history.error = nil
        await cache.offer(cacheKey, sequence: sequence, projection: projection, history: history)
        await cache.flush(cacheKey)
        note("cache saved at \(sequence)")
        cacheDisordered = !freshSinceDisorder
    }

    /// The app quits and comes back: the view starts from the disk cache, then resubscribes.
    func restart() {
        guard options.cache else { return }
        disconnect()
        historyRequest = nil
        client = ThreadReducer(threadId: server.threadId)
        pipeline = TimelinePipeline()
        shown = []
        optimistic = []
        observed.append((nil, false))
        onlyStreamingText = true
        if let snapshot = cache.load(cacheKey) {
            note("restart from cache at \(snapshot.snapshotSequence)")
            freshSinceDisorder = !cacheDisordered
            let changes = client.applySnapshot(snapshot)
            check(projectionChanged: changes.projectionChanged)
        } else {
            note("restart, no cache")
            check(projectionChanged: true)
        }
    }

    // MARK: Run

    func run() async -> [String] {
        connect()
        var idle = 0
        while !server.done || !inbox.isEmpty, idle < 10_000 {
            idle += 1
            switch rng.int(0...99) {
            case 0..<30: publish()
            case 30..<70: deliver()
            case 70..<74: disconnect()
            case 74..<80: if !connected { connect() } else { deliver() }
            case 80..<87: history()
            case 87..<93: toggle()
            case 93..<96: await saveCache()
            case 96..<98: restart()
            case 98: replaceSession()
            default: if !connected { connect() }
            }
            if !problems.isEmpty { return problems }
        }
        return catchUp()
    }

    /// Ends the run: resubscribe, take everything, load every older page, then compare.
    func catchUp() -> [String] {
        connect(forceSnapshot: !freshSinceDisorder)
        while !inbox.isEmpty { deliver() }
        var pages = 0
        while client.history.hasMoreHistory || historyRequest != nil, pages < 500 {
            history()
            pages += 1
        }
        check(projectionChanged: false)
        if client.history.loading { problems.append("seed \(seed): history still loading after catch-up") }
        if !problems.isEmpty { return problems }
        guard let mine = client.projection else { return ["seed \(seed): no projection at the end"] }
        let theirs = server.projection
        if mine.visibleTurnItems != theirs.visibleTurnItems {
            let a = mine.visibleTurnItems.map(\.sourceItemId.rawValue), b = theirs.visibleTurnItems.map(\.sourceItemId.rawValue)
            let first = (0..<min(a.count, b.count)).first { mine.visibleTurnItems[$0] != theirs.visibleTurnItems[$0] } ?? min(a.count, b.count)
            problems.append("seed \(seed): rows differ from the server after catch-up at \(first): "
                            + "\(a.dropFirst(first).prefix(3)) vs \(b.dropFirst(first).prefix(3)) (\(a.count) vs \(b.count))")
            if ProcessInfo.processInfo.environment["CW_STRESS_VERBOSE"] != nil, first < min(a.count, b.count) {
                problems.append("mine \(mine.visibleTurnItems[first])")
                problems.append("server \(theirs.visibleTurnItems[first])")
                problems.append("full log: " + log.joined(separator: "\n"))
            }
        }
        func sorted<T: Identifiable>(_ list: [T]) -> [T] where T.ID: Comparable { list.sorted { $0.id < $1.id } }
        if sorted(mine.runs) != sorted(theirs.runs) { problems.append("seed \(seed): runs differ after catch-up") }
        if sorted(mine.attempts) != sorted(theirs.attempts) { problems.append("seed \(seed): attempts differ after catch-up") }
        if sorted(mine.nodes) != sorted(theirs.nodes) { problems.append("seed \(seed): nodes differ after catch-up") }
        if mine.thread != theirs.thread { problems.append("seed \(seed): thread differs after catch-up") }
        // What the user sees agrees with the server: run state, open requests and the rows.
        if TimelineRunState(projection: mine) != TimelineRunState(projection: theirs) { problems.append("seed \(seed): run state differs after catch-up") }
        let myRequests = PendingRequests.derive(mine), serverRequests = PendingRequests.derive(theirs)
        if myRequests != serverRequests {
            problems.append("seed \(seed): pending requests differ after catch-up: approvals \(myRequests.approvals.map(\.requestId)) vs "
                            + "\(serverRequests.approvals.map(\.requestId)), questions \(myRequests.userInputs.map(\.requestId)) vs \(serverRequests.userInputs.map(\.requestId))")
            if ProcessInfo.processInfo.environment["CW_STRESS_VERBOSE"] != nil {
                problems.append("mine \(myRequests)")
                problems.append("server \(serverRequests)")
            }
        }
        // A bounded snapshot keeps only recent messages and older pages bring none, so like T3
        // (threadCheckpoints.ts:29-52) older turns lose their changed-files card. Compare without it there.
        func comparable(_ rows: [TimelineRow]) -> [TimelineRow] {
            guard options.bounded else { return rows }
            return rows.map { row in
                guard case .message(let m, let p, let meta, let copy, let streaming, _) = row.kind else { return row }
                var row = row
                row.kind = .message(m, projectedItem: p, showAssistantMeta: meta, showAssistantCopyButton: copy, assistantCopyStreaming: streaming, turnDiffSummary: nil)
                return row
            }
        }
        let myRows = comparable(TimelineRows.derive(TimelineRowsInput(projection: mine)))
        let serverRows = comparable(TimelineRows.derive(TimelineRowsInput(projection: theirs)))
        if myRows != serverRows {
            let first = (0..<min(myRows.count, serverRows.count)).first { myRows[$0] != serverRows[$0] } ?? min(myRows.count, serverRows.count)
            problems.append("seed \(seed): rows differ from the server's after catch-up at \(first): "
                            + "\(myRows.dropFirst(first).prefix(2).map(\.id)) vs \(serverRows.dropFirst(first).prefix(2).map(\.id))")
        }
        if client.lastSequence != server.sequence { problems.append("seed \(seed): cursor \(client.lastSequence ?? -1) vs \(server.sequence)") }
        return problems
    }
}

extension RunId: @retroactive Comparable { public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue } }
extension RunAttemptId: @retroactive Comparable { public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue } }
extension NodeId: @retroactive Comparable { public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue } }

extension Array {
    func randomElement(using rng: inout StressRNG) -> Element? {
        isEmpty ? nil : self[rng.int(0...count - 1)]
    }
}

extension ArraySlice {
    func randomElement(using rng: inout StressRNG) -> Element? { Array(self).randomElement(using: &rng) }
}

@Suite(.serialized) struct ThreadStressTests {
    /// Seeds per configuration: a few in `swift test`, `CW_STRESS_ITERATIONS` for a long run.
    static var iterations: Int { ProcessInfo.processInfo.environment["CW_STRESS_ITERATIONS"].flatMap(Int.init) ?? 10 }
    static var firstSeed: UInt64 { ProcessInfo.processInfo.environment["CW_STRESS_SEED"].flatMap(UInt64.init) ?? 1 }

    static func run(_ options: ThreadStressRun.Options, label: String) async throws {
        var features = Set<String>()
        var failures: [String] = []
        var worst: (ms: Double, what: String) = (0, "")
        var times: [Double] = []
        var stepsTotal = 0
        for seed in firstSeed..<(firstSeed + UInt64(iterations)) {
            let run = try ThreadStressRun(seed: seed, options: options)
            let problems = await run.run()
            features.formUnion(run.features)
            stepsTotal += run.steps
            times += run.normalStepMs
            if run.slowest.ms > worst.ms { worst = (run.slowest.ms, "seed \(seed): \(run.slowest.what)") }
            if !problems.isEmpty {
                failures.append((problems + ["last actions:"] + run.log.suffix(12)).joined(separator: "\n  "))
                if failures.count >= 3 { break }
            }
        }
        times.sort()
        let p50 = times.isEmpty ? 0 : times[times.count / 2], p99 = times.isEmpty ? 0 : times[times.count * 99 / 100]
        print("stress \(label): \(iterations) seeds, \(stepsTotal) steps; normal steps p50 \(String(format: "%.2f", p50)) ms, "
              + "p99 \(String(format: "%.2f", p99)) ms, slowest \(String(format: "%.1f", worst.ms)) ms (\(worst.what))")
        #expect(failures.isEmpty, "\(label):\n\(failures.joined(separator: "\n"))")
        if iterations >= 8, options.mode == .normal {
            for feature in ["queued-run", "approval", "question", "superseded-attempt", "compaction", "subagent", "interrupted", "failed", "steer",
                            "provider-retry-recovered", "tool-failed", "overlapping-runs", "rolled-back", "unknown-events"] {
                #expect(features.contains(feature), "\(label): no seed exercised \(feature)")
            }
        }
    }

    @Test func boundedWindowWithReconnectsPagesAndCache() async throws {
        try await Self.run(ThreadStressRun.Options(), label: "bounded")
    }

    @Test func fullSnapshotsWithOutOfOrderDeliveries() async throws {
        var options = ThreadStressRun.Options()
        options.bounded = false
        options.outOfOrder = true
        try await Self.run(options, label: "out of order")
    }

    /// A stress run's projections, in the order the pipeline saw them.
    static func observe(seed: UInt64, options: ThreadStressRun.Options) async throws -> (problems: [String], steps: [(ThreadProjection?, Bool)]) {
        let run = try ThreadStressRun(seed: seed, options: options)
        let problems = await run.run()
        return (problems, run.observed)
    }

    /// The same streams through the real panel: view model, off-main row passes that coalesce
    /// updates, and the timeline view. After the passes settle, the panel shows a fresh derive's
    /// rows and lays them out without overlaps.
    @MainActor @Test func panelFollowsStressedStreams() async throws {
        let seeds = max(3, Self.iterations / 4)
        for seed in Self.firstSeed..<(Self.firstSeed + UInt64(seeds)) {
            var options = ThreadStressRun.Options()
            options.outOfOrder = seed % 3 == 0
            let (problems, steps) = try await Self.observe(seed: seed, options: options)
            #expect(problems.isEmpty, "\(problems)")
            let panel = ThreadPanelView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
            if seed % 2 == 0 { panel.model.backgroundRowsThreshold = 0 }
            let settleEvery = Int(seed % 3) + 1
            for (n, (projection, onlyText)) in steps.enumerated() {
                panel.setProjection(projection, projectTitle: "demo-repo", workspaceRoot: nil, onlyStreamingText: onlyText)
                guard n % settleEvery == 0 || n == steps.count - 1, let projection else { continue }
                await panel.model.rowsSettled()
                panel.layoutSubtreeIfNeeded()
                let expected = TimelineRows.derive(TimelineRowsInput(projection: projection))
                let rows = panel.model.items.map(\.row)
                #expect(rows == expected, "seed \(seed) step \(n): rows \(rows.map(\.id)) expected \(expected.map(\.id))")
                #expect(panel.timeline.items == panel.model.items, "seed \(seed) step \(n): timeline items")
                let layout = panel.timeline.layoutProblems()
                #expect(layout.isEmpty, "seed \(seed) step \(n): \(layout)")
                if rows != expected || !layout.isEmpty { return }
            }
        }
    }

    /// A long thread: after the snapshot, every live update (streaming text, tool progress, status
    /// changes, a new prompt) touches only the rows it changed. Streaming answer text patches its
    /// rows without a full row pass, and no step hands the view more than a few rows to rebuild. The
    /// default run uses about 400 rows; a long run (`CW_STRESS_ITERATIONS`) about 2,000. Counting
    /// work instead of timing it catches the same O(rows) regression without depending on the
    /// machine's load; `scripts/perf-review` measures the time.
    @Test func largeThreadStepsTouchOnlyChangedRows() throws {
        let long = ProcessInfo.processInfo.environment["CW_STRESS_ITERATIONS"] != nil
        var generator = StressThreadGenerator(seed: 7, runCount: long ? 260 : 50, maxSteps: 12)
        let server = try StressServer(script: generator.generate())
        let tailEvents = long ? 600 : 150
        _ = server.publish(server.items.count - tailEvents)
        var client = ThreadReducer(threadId: server.threadId)
        client.applySnapshot(server.snapshot(bounded: false, compact: false))
        let pipeline = TimelinePipeline()
        func request(_ changed: Bool) -> TimelinePipeline.Request {
            TimelinePipeline.Request(projection: client.projection, projectionChanged: changed, expandedRunIds: [],
                                     expandedAttemptIds: [], expandedWorkGroupIds: [], pending: [])
        }
        var rows = pipeline.run(request(true))?.rows ?? []
        #expect(rows.count > 200, "the thread is long enough to show a per-step blow-up")
        var textSteps = 0, answerSteps = 0, steps = 0, widest = 0
        while !server.done {
            let batch = server.publish(1)
            let passes = pipeline.fullPasses
            let changes = client.apply(batch)
            let result = pipeline.run(request(changes.projectionChanged))
            steps += 1
            if let result { rows = result.rows }
            // Rows the view has to rebuild for this step.
            let touched: Int
            switch result?.change {
            case nil: touched = 0
            case .rows(let changed): touched = changed.count
            case .tail(let first): touched = rows.count - first
            case .head(let replaced, let inserted): touched = max(replaced, inserted)
            case .all, .thread: touched = rows.count
            }
            widest = max(widest, touched)
            #expect(touched <= 12, "step \(steps): \(touched) of \(rows.count) rows changed (\(String(describing: result?.change)))")
            if changes.projectionChanged, changes.onlyStreamingText {
                textSteps += 1
                #expect(touched <= 2, "step \(steps): streaming text changed \(touched) rows")
                // An answer's text patches its rows in place (T3's `replaceStreamingMessageRows`); other streaming
                // items, like reasoning, take the full row pass.
                if case .rows(let changed)? = result?.change, !changed.isEmpty, changed.allSatisfy({ i in
                    switch rows[i].kind { case .message, .assistantMeta: true; default: false }
                }) {
                    answerSteps += 1
                    #expect(pipeline.fullPasses == passes, "step \(steps): streaming answer text ran a full row pass")
                }
            }
        }
        print("large thread: \(rows.count) rows, \(steps) steps, \(textSteps) text-only, \(answerSteps) answer text, \(pipeline.fullPasses) full passes, widest step \(widest) rows")
        #expect(answerSteps >= 5, "the tail streams answer text")
    }

    @Test func forkedThreadsWithInheritedRows() async throws {
        var options = ThreadStressRun.Options()
        options.mode = .forked
        options.runs = 4
        try await Self.run(options, label: "forked")
    }

    @Test func providerNativeSubagentThreads() async throws {
        var options = ThreadStressRun.Options()
        options.mode = .providerSubagent
        options.runs = 3
        try await Self.run(options, label: "provider subagent")
    }
}
