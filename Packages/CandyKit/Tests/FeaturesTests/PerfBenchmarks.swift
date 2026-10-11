import AppKit
import Foundation
import Testing
import T3Protocol
import T3Store
@testable import Features

// Micro-benchmarks for scripts/perf-review. Deterministic inputs; each prints one line
// `PERF {"name":...,"median_ms":...}` with the median, min and max of several timed runs.
// Off by default. Run in release:
//   CW_BENCH=1 swift test -c release -Xswiftc -enable-testing --filter Perf
// The file only uses APIs that also exist at milestone 5 (dd10f48), so perf-review can copy it into an
// older checkout that lacks it.

private func milliseconds(_ d: Duration) -> Double {
    Double(d.components.seconds) * 1e3 + Double(d.components.attoseconds) / 1e15
}

/// Runs `body` once to warm up, then `runs` times, and prints the PERF line. `inner` passes per run keep
/// each timed run well above the clock's resolution; the reported times are per pass.
private func measure(_ name: String, runs: Int = 9, inner: Int = 1, extra: [String: Any] = [:], _ body: () throws -> Void) rethrows {
    try body()
    var times: [Double] = []
    for _ in 0..<runs {
        let start = ContinuousClock.now
        for _ in 0..<inner { try body() }
        times.append(milliseconds(ContinuousClock.now - start) / Double(inner))
    }
    times.sort()
    var line: [String: Any] = ["name": name, "median_ms": times[runs / 2], "min_ms": times[0], "max_ms": times[runs - 1], "runs": runs]
    line.merge(extra) { $1 }
    let data = try! JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])
    print("PERF " + String(decoding: data, as: UTF8.self))
}

private let fixtureDir = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "fixtures/transcripts")

/// One recorded transcript's server frames, with the request tag each request id belongs to.
private struct Transcript {
    var frames: [Data] = []
    var tags: [String: String] = [:]
    var threadOf: [String: String] = [:]

    init(_ url: URL) throws {
        for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
            let o = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
            guard o["kind"] as? String == "ws", let body = o["body"] as? [String: Any] else { continue }
            if o["dir"] as? String == "send" {
                if let id = body["id"] as? String, let tag = body["tag"] as? String {
                    tags[id] = tag
                    if let threadId = (body["payload"] as? [String: Any])?["threadId"] as? String { threadOf[id] = threadId }
                }
            } else {
                frames.append(try JSONSerialization.data(withJSONObject: body))
            }
        }
    }
}

private func transcripts() throws -> [(String, Transcript)] {
    try FileManager.default.contentsOfDirectory(atPath: fixtureDir.path).filter { $0.hasSuffix(".jsonl") }.sorted()
        .map { ($0, try Transcript(fixtureDir.appending(path: $0))) }
}

/// Every `orchestration.subscribeThread` stream in the fixtures, decoded, one array per Chunk.
private func threadStreams() throws -> [(threadId: String, chunks: [[ThreadStreamItem]])] {
    var out: [(String, [[ThreadStreamItem]])] = []
    for (_, t) in try transcripts() {
        var byRequest: [String: [[ThreadStreamItem]]] = [:]
        var order: [String] = []
        for frame in t.frames {
            for message in try RPCFrame.decodeServer(frame) {
                guard case .chunk(.string(let id), let values) = message, t.tags[id] == "orchestration.subscribeThread" else { continue }
                if byRequest[id] == nil { order.append(id) }
                byRequest[id, default: []].append(try values.map { try $0.decode(as: ThreadStreamItem.self) })
            }
        }
        out += order.map { (t.threadOf[$0] ?? $0, byRequest[$0]!) }
    }
    return out
}

/// A long assistant reply: headings, paragraphs with inline styles, lists, code and tables, about 60 KB.
private func longReply(sections: Int = 120) -> String {
    var s = "# Report\n\n"
    for i in 1...sections {
        s += "## Section \(i)\n\nParagraph \(i) has **bold**, *italic*, `inline code` and a [link](https://example.com/\(i)). "
        s += String(repeating: "Plain words fill the line so wrapping has work to do. ", count: 3) + "\n\n"
        if i % 3 == 0 { s += "- first item \(i)\n- second item with `code`\n  - nested item\n- third item\n\n" }
        if i % 4 == 0 { s += "```swift\nfunc section\(i)() -> Int {\n    let values = [1, 2, 3]\n    return values.reduce(0, +) * \(i)\n}\n```\n\n" }
        if i % 10 == 0 { s += "| Name | Value |\n|:--|--:|\n| alpha | \(i) |\n| beta | \(i * 2) |\n\n" }
    }
    return s
}

/// `count` threads spread over 20 projects with every sidebar status, timestamps a minute apart.
private func bigSnapshot(threads count: Int) -> ShellSnapshot {
    let projects = (0..<20).map { SidebarPreview.project("project-\($0)", "repo-\($0)") }
    let kinds: [SidebarPreview.Kind] = [.done, .read, .read, .done, .input, .approval, .working, .failed, .waiting]
    let threads = (0..<count).map { i in
        SidebarPreview.thread("thread-\(i)", "Thread number \(i) with a title long enough to truncate", project: "project-\(i % 20)",
                              kind: kinds[i % kinds.count], minutesAgo: Double(i) + 1)
    }
    return SidebarPreview.snapshot(projects: projects, threads: threads)
}


// MARK: Synthetic huge thread

/// The recorded `subscribeThread` snapshot with the most rows, as the server sent it.
private func largestSnapshot() throws -> JSONValue {
    var best: JSONValue?
    var bestRows = -1
    for (_, t) in try transcripts() {
        for frame in t.frames {
            for message in try RPCFrame.decodeServer(frame) {
                guard case .chunk(.string(let id), let values) = message, t.tags[id] == "orchestration.subscribeThread" else { continue }
                for v in values where v["kind"]?.stringValue == "snapshot" {
                    guard case .array(let rows)? = v["projection"]?["visibleTurnItems"], rows.count > bestRows else { continue }
                    best = v
                    bestRows = rows.count
                }
            }
        }
    }
    return try #require(best)
}

/// Ids get a per-copy suffix, ordinals a per-copy offset; the thread and project stay the same.
private func copy(_ value: JSONValue, _ k: Int, key: String? = nil) -> JSONValue {
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

/// A thread of `copies` times the largest recorded snapshot's turns, as one server Chunk frame.
/// `window` copies of rows and messages go in the frame, like the server's bounded snapshot
/// (10 user turns or 75 rows; the recording has 3 turns and 19 rows), while runs, attempts, nodes,
/// checkpoints, requests and provider turns cover the whole thread, as `buildBoundedThreadProjection`
/// sends them (threadHistoryPaging.ts:458). `window == copies` is the whole history loaded.
private func syntheticThreadFrame(copies: Int, window: Int, reply: String? = nil) throws -> (frame: Data, threadId: String) {
    let base = try largestSnapshot()
    guard case .object(var snapshot) = base, case .object(var projection)? = base["projection"] else { throw CancellationError() }
    let control = ["runs", "attempts", "nodes", "checkpoints", "runtimeRequests", "providerTurns"]
    let windowed = ["visibleTurnItems", "messages"]
    for key in control + windowed {
        guard case .array(let items)? = projection[key] else { continue }
        let range = control.contains(key) ? 0..<copies : (copies - window)..<copies
        var out: [JSONValue] = []
        for k in range { out += items.map { copy($0, k) } }
        if let reply {
            // Every assistant message in the window gets a long markdown reply.
            out = out.map { value in
                guard case .object(var o) = value else { return value }
                if case .object(var item)? = o["item"], item["type"]?.stringValue == "assistant_message" {
                    item["text"] = .string(reply)
                    o["item"] = .object(item)
                } else if o["role"]?.stringValue == "assistant" {
                    o["text"] = .string(reply)
                }
                return .object(o)
            }
        }
        if key == "visibleTurnItems" {
            out = out.enumerated().map { i, row in
                guard case .object(var o) = row else { return row }
                o["position"] = .number(Double(i))
                return .object(o)
            }
        }
        projection[key] = .array(out)
    }
    snapshot["projection"] = .object(projection)
    if window < copies {
        snapshot["hasMoreHistory"] = .bool(true)
        snapshot["historyCursor"] = .string("synthetic-cursor")
    }
    let frame = try RPCFrame.encode(RPCServerMessage.chunk(requestId: .string("1"), values: [.object(snapshot)]))
    let threadId = projection["thread"]?["id"]?.stringValue ?? ""
    return (frame, threadId)
}

/// Every stage of opening a thread from the frame to the laid-out panel, each timed on its own.
@MainActor
private func measureThreadOpen(_ name: String, copies: Int, window: Int, reply: String? = nil) throws {
    let (frame, threadId) = try syntheticThreadFrame(copies: copies, window: window, reply: reply)
    var value: JSONValue = .null
    try measure("\(name)_parse", runs: 5, extra: ["bytes": frame.count]) {
        guard case .chunk(_, let values)? = try RPCFrame.decodeServer(frame).first else { return }
        value = values[0]
    }
    var item: ThreadStreamItem?
    try measure("\(name)_decode", runs: 5) { item = try value.decode(as: ThreadStreamItem.self) }
    var projection: ThreadProjection?
    let decoded = try #require(item)
    measure("\(name)_reduce", runs: 5) {
        var reducer = ThreadReducer(threadId: ThreadId(threadId))
        reducer.apply([decoded])
        projection = reducer.projection
    }
    let p = try #require(projection)
    var input: TimelineRowsInput?
    measure("\(name)_entries", runs: 5, extra: ["rows": p.visibleTurnItems.count, "runs": p.runs.count, "nodes": p.nodes.count]) {
        input = TimelineRowsInput(projection: p)
    }
    var rows = 0
    let i = try #require(input)
    measure("\(name)_derive", runs: 5) { rows = TimelineRows.derive(i).count }
    // A fresh panel each run, so no row heights are cached.
    var panels = (0..<6).map { _ in ThreadPanelView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800)) }
    measure("\(name)_panel", runs: 5, extra: ["timeline_rows": rows]) {
        let panel = panels.removeLast()
        panel.setProjection(p, projectTitle: "demo-repo", workspaceRoot: nil)
        panel.layoutSubtreeIfNeeded()
    }
    #expect(rows > 0)
}

/// The item with some wire fields replaced.
private func replacing(_ item: TurnItem, _ fields: [String: JSONValue]) throws -> TurnItem {
    guard case .object(var o) = item.raw else { return item }
    o.merge(fields) { $1 }
    return try TurnItem(json: .object(o))
}

/// A thread that is streaming: the newest run runs and its last answer streams.
private func streamingProjection(copies: Int, window: Int) throws -> (ThreadProjection, answer: Int, tool: Int) {
    let (frame, threadId) = try syntheticThreadFrame(copies: copies, window: window)
    guard case .chunk(_, let values)? = try RPCFrame.decodeServer(frame).first else { throw CancellationError() }
    var reducer = ThreadReducer(threadId: ThreadId(threadId))
    reducer.apply([try values[0].decode(as: ThreadStreamItem.self)])
    var p = try #require(reducer.projection)
    let run = try #require(p.runs.indices.max { p.runs[$0].ordinal < p.runs[$1].ordinal })
    p.runs[run].status = .running
    p.runs[run].completedAt = nil
    let answer = try #require(p.visibleTurnItems.lastIndex { $0.item.type == .assistantMessage })
    p.visibleTurnItems[answer].item = try replacing(p.visibleTurnItems[answer].item, ["streaming": .bool(true), "status": .string("running")])
    let tool = try #require(p.visibleTurnItems.lastIndex {
        $0.item.type != .assistantMessage && $0.item.type != .userMessage && $0.item.type != .checkpoint && $0.item.type != .todoList
    })
    return (p, answer, tool)
}

/// Main-thread cost of one update to a thread already on screen: a streamed answer growing by a
/// word (`_stream`), and a tool row flipping between running and completed (`_tool`). The time
/// runs from `setProjection` until the timeline holds the new rows and is laid out, counting
/// only main-thread work (rows derived off the main thread are awaited, not counted).
@MainActor
private func measureThreadUpdate(_ name: String, copies: Int, window: Int) async throws {
    let (base, answer, tool) = try streamingProjection(copies: copies, window: window)
    let panel = ThreadPanelView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
    panel.setProjection(base, projectTitle: "demo-repo", workspaceRoot: nil)
    await panel.model.rowsSettled()
    panel.layoutSubtreeIfNeeded()
    let text = base.visibleTurnItems[answer].item.text
    var k = 0
    func update(_ change: (inout ThreadProjection) throws -> Void) async throws -> Double {
        var p = base
        try change(&p)
        let start = ContinuousClock.now
        panel.setProjection(p, projectTitle: "demo-repo", workspaceRoot: nil)
        var main = milliseconds(ContinuousClock.now - start)
        main += await panel.model.rowsSettled()
        let layout = ContinuousClock.now
        panel.layoutSubtreeIfNeeded()
        return main + milliseconds(ContinuousClock.now - layout)
    }
    func report(_ suffix: String, _ times: [Double], rows: Int) {
        let sorted = times.sorted()
        let line: [String: Any] = ["name": "\(name)_\(suffix)", "median_ms": sorted[sorted.count / 2], "min_ms": sorted[0],
                                   "max_ms": sorted[sorted.count - 1], "runs": sorted.count, "timeline_rows": rows]
        let data = try! JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])
        print("PERF " + String(decoding: data, as: UTF8.self))
    }
    var stream: [Double] = []
    for _ in 0..<12 {
        k += 1
        let words = String(repeating: " word", count: k)
        stream.append(try await update { p in
            p.visibleTurnItems[answer].item = try replacing(p.visibleTurnItems[answer].item, ["text": .string(text + words)])
        })
    }
    report("stream", Array(stream.dropFirst(2)), rows: panel.model.items.count)
    var tools: [Double] = []
    for i in 0..<12 {
        tools.append(try await update { p in
            p.visibleTurnItems[tool].item = try replacing(p.visibleTurnItems[tool].item, ["status": .string(i % 2 == 0 ? "running" : "completed")])
        })
    }
    report("tool", Array(tools.dropFirst(2)), rows: panel.model.items.count)
    // A new tool call at the end of the running turn.
    var appends: [Double] = []
    for i in 0..<12 {
        appends.append(try await update { p in
            var row = p.visibleTurnItems[tool]
            row.item = try replacing(row.item, ["id": .string("appended-\(i)"), "status": .string("running"),
                                                "ordinal": .number(Double(row.item.ordinal + 1_000_000 + i))])
            row.sourceItemId = row.item.id
            row.position = p.visibleTurnItems.count
            p.visibleTurnItems.append(row)
        })
    }
    report("append", Array(appends.dropFirst(2)), rows: panel.model.items.count)

    // The stages on their own, each a one-row change against the previous update.
    func variants(_ change: (inout ThreadProjection, Int) throws -> Void) throws -> [ThreadProjection] {
        try (0..<2).map { i in var p = base; try change(&p, i); return p }
    }
    let streamed = try variants { p, i in
        p.visibleTurnItems[answer].item = try replacing(p.visibleTurnItems[answer].item, ["text": .string(text + String(repeating: " word", count: i + 1))])
    }
    let tooled = try variants { p, i in
        p.visibleTurnItems[tool].item = try replacing(p.visibleTurnItems[tool].item, ["status": .string(i == 0 ? "running" : "completed")])
    }
    for (suffix, pair) in [("stream", streamed), ("tool", tooled)] {
        var memo = TimelineRowsInput.Memo()
        var flip = 0
        var last = TimelineRowsInput.derive(projection: pair[0], memo: &memo)
        measure("\(name)_\(suffix)_entries", runs: 9) {
            flip ^= 1
            last = TimelineRowsInput.derive(projection: pair[flip], memo: &memo)
        }
        var memo2 = TimelineRowsInput.Memo()
        let a = TimelineRowsInput.derive(projection: pair[0], memo: &memo2).input
        let (b, changed) = TimelineRowsInput.derive(projection: pair[1], memo: &memo2)
        let derivedA = TimelineRows.Derived(a)
        if let changed, TimelineRows.patchingStreamingText(derivedA, input: b, changedEntries: changed) != nil {
            measure("\(name)_\(suffix)_rows_patch", runs: 9) { _ = TimelineRows.patchingStreamingText(derivedA, input: b, changedEntries: changed) }
        } else {
            measure("\(name)_\(suffix)_rows_offmain", runs: 5) { _ = TimelineRows.Derived(b) }
        }
        _ = last
    }
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["CW_BENCH"] != nil), .serialized)
@MainActor
struct PerfBenchmarks {
    @Test func decodeFixtures() throws {
        let all = try transcripts()
        let bytes = all.reduce(0) { $0 + $1.1.frames.reduce(0) { $0 + $1.count } }
        var items = 0
        try measure("decode_fixtures", extra: ["bytes": bytes]) {
            items = 0
            for (_, t) in all {
                for frame in t.frames {
                    for message in try RPCFrame.decodeServer(frame) {
                        guard case .chunk(.string(let id), let values) = message else { continue }
                        for value in values {
                            switch t.tags[id] {
                            case "orchestration.subscribeThread": _ = try value.decode(as: ThreadStreamItem.self)
                            case "orchestration.subscribeShell": _ = try value.decode(as: ShellStreamItem.self)
                            default: continue
                            }
                            items += 1
                        }
                    }
                }
            }
        }
        #expect(items > 0)
    }

    @Test func threadReducerAndTimeline() throws {
        let streams = try threadStreams()
        let largest = try #require(streams.max { $0.chunks.joined().count < $1.chunks.joined().count })
        let itemCount = largest.chunks.joined().count
        var projection: ThreadProjection?
        measure("thread_reducer", inner: 20, extra: ["items": itemCount]) {
            var reducer = ThreadReducer(threadId: ThreadId(largest.threadId))
            for chunk in largest.chunks { _ = reducer.apply(chunk) }
            projection = reducer.projection
        }
        let p = try #require(projection)
        var rows = 0
        measure("timeline_rows", inner: 50, extra: ["turn_items": p.visibleTurnItems.count]) {
            rows = TimelineRows.derive(TimelineRowsInput(projection: p)).count
        }
        #expect(rows > 0)
    }

    /// A huge thread (300 copies of the largest recording: 900 runs, 3,600 nodes) opened as the
    /// server sends it, a bounded window of 3 copies; then the same thread with all history loaded.
    @Test func hugeThreadOpen() throws {
        try measureThreadOpen("huge_open", copies: 300, window: 3)
        try measureThreadOpen("huge_full", copies: 300, window: 300)
        // The bounded window again, every reply 6 KB of markdown with code and tables.
        try measureThreadOpen("huge_open_long", copies: 300, window: 3, reply: longReply(sections: 12))
    }

    /// The huge thread's bounded window through the disk cache: `write` encodes, compresses and
    /// writes it (off the main thread in the app), `load` reads, decompresses and decodes it, the
    /// step a cold open takes before its first frame instead of the network.
    @Test func hugeThreadCache() async throws {
        let (frame, threadId) = try syntheticThreadFrame(copies: 300, window: 3)
        guard case .chunk(_, let values)? = try RPCFrame.decodeServer(frame).first else { throw CancellationError() }
        var reducer = ThreadReducer(threadId: ThreadId(threadId))
        reducer.apply([try values[0].decode(as: ThreadStreamItem.self)])
        let p = try #require(reducer.projection)
        let dir = FileManager.default.temporaryDirectory.appending(path: "cw-bench-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = ThreadCache(directory: dir)
        let key = ThreadCache.Key(environmentId: "bench", threadId: p.thread.id)
        var times: [Double] = []
        for _ in 0..<5 {
            let start = ContinuousClock.now
            await cache.offer(key, sequence: 1, projection: p, history: reducer.history)
            await cache.flush(key)
            times.append(milliseconds(ContinuousClock.now - start))
        }
        times.sort()
        let bytes = (try? FileManager.default.attributesOfItem(atPath: cache.fileURL(key).path)[.size] as? Int) ?? 0
        let line: [String: Any] = ["name": "huge_cache_write", "median_ms": times[2], "min_ms": times[0], "max_ms": times[4], "runs": 5,
                                   "bytes": bytes, "json_bytes": frame.count]
        print("PERF " + String(decoding: try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]), as: UTF8.self))
        var rows = 0
        measure("huge_cache_load", runs: 5, extra: ["bytes": bytes]) {
            rows = cache.load(key)?.projection.visibleTurnItems.count ?? 0
        }
        #expect(rows > 0)
    }

    /// One update to the huge thread on screen with all 5,700 rows loaded, as streaming sends them.
    @Test func hugeThreadUpdate() async throws {
        try await measureThreadUpdate("huge_update", copies: 300, window: 300)
    }

    @Test func markdownLayout() {
        let text = longReply()
        var height: CGFloat = 0
        measure("markdown_parse", inner: 5, extra: ["bytes": text.utf8.count]) {
            _ = MarkdownDocument(parsing: text)
        }
        // A reply of 2,400 short lines (the sandbox's "Numbers 1 to 1000" thread): one paragraph of soft breaks.
        let lines = (1...2400).map { "number \($0)" }.joined(separator: "\n")
        measure("markdown_parse_lines", inner: 3, extra: ["bytes": lines.utf8.count]) {
            _ = MarkdownDocument(parsing: lines)
        }
        let doc = MarkdownDocument(parsing: text)
        measure("markdown_layout", extra: ["blocks": doc.blocks.count]) {
            height = MarkdownLayout(document: doc, width: 680).height
        }
        #expect(height > 1000)
    }

    /// A Codex-style answer streaming word by word: main-thread time of one delta near the end of a
    /// 2,000-word answer. `_full` is the path before 2026-10-12 (parse and lay out the whole message
    /// per delta), `_incremental` the streaming parse plus layout reuse that replaced it.
    @Test func markdownStreamDelta() {
        var text = ""
        while text.split(separator: " ").count < 2_000 { text += longReply(sections: 4) }
        let words = text.split(separator: " ", omittingEmptySubsequences: false)
        let deltas = (words.count - 40..<words.count).map { words.prefix($0).joined(separator: " ") }
        let start = MarkdownDocument.parse(deltas[0], extending: nil)
        var parse = start
        var layout = MarkdownLayout(document: start.document, width: 680)
        var k = 0
        measure("markdown_stream_delta_full", runs: 9, inner: 10, extra: ["words": words.count]) {
            k = (k + 1) % deltas.count
            _ = MarkdownLayout(document: MarkdownDocument(parsing: deltas[k]), width: 680)
        }
        k = 0
        measure("markdown_stream_delta_incremental", runs: 9, inner: 10, extra: ["words": words.count]) {
            k += 1
            if k == deltas.count { k = 1; parse = start; layout = MarkdownLayout(document: start.document, width: 680) }
            parse = MarkdownDocument.parse(deltas[k], extending: parse)
            layout = MarkdownLayout(document: parse.document, width: 680, reusing: layout)
        }
        #expect(layout.height > 1000)
    }

    @Test func sidebarModel() {
        let snapshot = bigSnapshot(threads: 1000)
        let nowMs = Int64(SidebarPreview.referenceNow.timeIntervalSince1970 * 1000)
        var count = 0
        measure("sidebar_items_1000", inner: 5, extra: ["threads": 1000]) {
            count = SidebarListBuilder.items(snapshot: snapshot, state: SidebarListState(), nowMs: nowMs).count
        }
        #expect(count > 0)
    }

    /// The side-by-side's 2,000-message thread and the huge thread, paged in to their start.
    @Test func historyPaging() async throws {
        let (frame, threadId) = try syntheticThreadFrame(copies: 300, window: 300)
        guard case .chunk(_, let values)? = try RPCFrame.decodeServer(frame).first else { throw CancellationError() }
        var reducer = ThreadReducer(threadId: ThreadId(threadId))
        reducer.apply([try values[0].decode(as: ThreadStreamItem.self)])
        let huge = try #require(reducer.projection)
        var seeded = huge
        seeded.visibleTurnItems = try seededMessages(pairs: 1000, threadId: threadId)
        seeded.runs = []
        seeded.attempts = []
        seeded.nodes = []
        seeded.checkpoints = []
        try await measurePaging("paging_seeded2000", seeded, window: 20, page: 40)
        try await measurePaging("paging_huge", huge, window: 75, page: 75)
    }
}

// MARK: History paging

/// The side-by-side's seeded thread: `pairs` question and reply pairs, message items only, no runs.
private func seededMessages(pairs: Int, threadId: String) throws -> [ProjectedTurnItem] {
    let words = "alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima mike november oscar papa".split(separator: " ")
    var rows: [ProjectedTurnItem] = []
    for i in 0..<pairs {
        for user in [true, false] {
            let n = rows.count
            let at = "2026-10-03T\(String(format: "%02d", 9 + n / 3600)):\(String(format: "%02d", (n / 60) % 60)):\(String(format: "%02d", n % 60)).000Z"
            let text = user ? "Question \(i + 1): say something about \(words[i % words.count])."
                : "Reply \(i + 1). " + (0..<(20 + (i * 7) % 60)).map { String(words[($0 + i) % words.count]) }.joined(separator: " ")
                    + (i % 5 == 0 ? "\n\n- first point\n- second point\n- third point" : "")
            let item = try TurnItem(json: .object([
                "id": .string("seed-item-\(n)"), "threadId": .string(threadId), "type": .string(user ? "user_message" : "assistant_message"),
                "messageId": .string("seed-message-\(n)"), "text": .string(text), "ordinal": .number(Double(n)),
                "status": .string("completed"), "startedAt": .string(at), "updatedAt": .string(at), "streaming": .bool(false),
            ]))
            rows.append(ProjectedTurnItem(local: item, position: n))
        }
    }
    return rows
}

/// Pages a thread's history in like the client: the newest `window` rows first, then older pages
/// of `page` rows through `mergeOlderHistory`, each laid out in the panel before the next. `main`
/// counts main-thread milliseconds (setProjection, applying rows derived off the main thread,
/// layout); `total` also counts the row passes off the main thread.
@MainActor
private func measurePaging(_ name: String, _ full: ThreadProjection, window: Int, page: Int) async throws {
    let all = full.visibleTurnItems
    var p = full
    p.visibleTurnItems = all.suffix(window).enumerated().map { i, row in var row = row; row.position = i; return row }
    // The merge skips page rows whose item the projection already holds, so only the window's are held.
    let windowIds = Set(p.visibleTurnItems.map(\.sourceItemId))
    p.turnItems = p.turnItems.filter { windowIds.contains($0.id) }
    let panel = ThreadPanelView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
    panel.setProjection(p, projectTitle: "demo-repo", workspaceRoot: nil)
    await panel.model.rowsSettled()
    panel.layoutSubtreeIfNeeded()
    var loaded = window
    var mains: [Double] = [], totals: [Double] = []
    while loaded < all.count {
        let older = Array(all[max(0, all.count - loaded - page)..<(all.count - loaded)])
        loaded += older.count
        p = ThreadReduction.mergeOlderHistory(p, older)
        let start = ContinuousClock.now
        panel.setProjection(p, projectTitle: "demo-repo", workspaceRoot: nil)
        var main = milliseconds(ContinuousClock.now - start)
        main += await panel.model.rowsSettled()
        let layout = ContinuousClock.now
        panel.layoutSubtreeIfNeeded()
        let end = ContinuousClock.now
        main += milliseconds(end - layout)
        mains.append(main)
        totals.append(milliseconds(end - start))
    }
    func report(_ suffix: String, _ times: [Double]) {
        let sorted = times.sorted()
        let line: [String: Any] = ["name": "\(name)_\(suffix)", "median_ms": sorted[sorted.count / 2], "min_ms": sorted[0],
                                   "max_ms": sorted[sorted.count - 1], "runs": sorted.count, "sum_ms": times.reduce(0, +),
                                   "last_ms": times.last ?? 0, "timeline_rows": panel.model.items.count]
        let data = try! JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])
        print("PERF " + String(decoding: data, as: UTF8.self))
    }
    report("main", mains)
    report("total", totals)
}
