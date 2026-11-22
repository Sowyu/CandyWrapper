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

/// The recordings the benchmarks were calibrated on. A later one, like 22-nightly-3473 with its 249-row thread, would
/// become the base of the synthetic threads and move every comparison with saved runs (docs/perf/README.md).
private let benchmarkFixtures: Set<String> = [
    "01-basic.jsonl", "02-turn.jsonl", "03-turn2.jsonl", "04-threads.jsonl", "05-composer.jsonl", "06-requests.jsonl",
    "07-queue.jsonl", "08-settings.jsonl", "09-reasoning-tools.jsonl", "20-nightly-3234.jsonl", "21-future-server.jsonl",
]

private func transcripts() throws -> [(String, Transcript)] {
    try FileManager.default.contentsOfDirectory(atPath: fixtureDir.path).filter { benchmarkFixtures.contains($0) }.sorted()
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
func syntheticThreadFrame(copies: Int, window: Int, reply: String? = nil) throws -> (frame: Data, threadId: String) {
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

/// The bounded window of `syntheticThreadFrame(copies: 300, window: 3)` with one settled run that did `work` commands
/// in a row, as a 4928 server sends it: every row (`deferred` false), or with `deferWork=1`, where a group over 150 rows
/// is its first row with a `deferredWork` cursor (`deferWorkHistoryRows`, threadHistoryPaging.ts:224-262 at 4928).
func longWorkFrame(work: Int, deferred: Bool) throws -> (frame: Data, threadId: String) {
    let (base, threadId) = try syntheticThreadFrame(copies: 300, window: 3)
    guard case .chunk(_, let values)? = try RPCFrame.decodeServer(base).first, case .object(var snapshot) = values[0],
          case .object(var projection)? = snapshot["projection"], case .array(var rows)? = projection["visibleTurnItems"],
          let at = rows.firstIndex(where: { $0["item"]?["type"]?.stringValue == "command_execution" }),
          case .object(let template) = rows[at], case .object(let item)? = template["item"]
    else { throw CancellationError() }
    let ordinal = item["ordinal"]?.doubleValue ?? 0
    // Later rows move up to make room for the group's ordinals.
    for i in rows.indices where i > at {
        guard case .object(var row) = rows[i], case .object(var later)? = row["item"] else { continue }
        later["ordinal"] = .number((later["ordinal"]?.doubleValue ?? 0) + Double(work))
        row["item"] = .object(later)
        rows[i] = .object(row)
    }
    var group: [JSONValue] = []
    for k in 1...work {
        var clone = item
        clone["id"] = .string("\(item["id"]?.stringValue ?? "w")-lw\(k)")
        clone["ordinal"] = .number(ordinal + Double(k))
        clone["input"] = .string("rg --files Sources/Module\(k) | head -50")
        clone["output"] = .string((0..<12).map { "Sources/Module\(k)/File\($0).swift" }.joined(separator: "\n"))
        var row = template
        row["item"] = .object(clone)
        row["sourceItemId"] = clone["id"]
        group.append(.object(row))
    }
    if deferred {
        var anchorItem = item
        anchorItem["deferredWork"] = .object([
            "cursor": .string("deferred-cursor"), "itemCount": .number(Double(work + 1)), "lastOrdinal": .number(ordinal + Double(work)),
        ])
        var anchor = template
        anchor["item"] = .object(anchorItem)
        rows[at] = .object(anchor)
    } else {
        rows.insert(contentsOf: group, at: at + 1)
    }
    rows = rows.enumerated().map { i, row in
        guard case .object(var o) = row else { return row }
        o["position"] = .number(Double(i))
        return .object(o)
    }
    projection["visibleTurnItems"] = .array(rows)
    snapshot["projection"] = .object(projection)
    return (try RPCFrame.encode(RPCServerMessage.chunk(requestId: .string("1"), values: [.object(snapshot)])), threadId)
}

/// Every stage of opening a thread from the frame to the laid-out panel, each timed on its own.
@MainActor
private func measureThreadOpen(_ name: String, copies: Int, window: Int, reply: String? = nil) throws {
    let (frame, threadId) = try syntheticThreadFrame(copies: copies, window: window, reply: reply)
    try measureFrameOpen(name, frame: frame, threadId: threadId)
}

@MainActor
private func measureFrameOpen(_ name: String, frame: Data, threadId: String) throws {
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
    // The same streamed word in a thread that holds one older question whose answer only its runtime request kept
    // (`createQuestionHistoryProjector`, #29105).
    let answeredStreamed = try streamed.map { projection in
        var p = projection
        var row = p.visibleTurnItems[tool]
        row.item = try replacing(row.item, [
            "id": .string("legacy-question"), "type": .string("user_input_request"), "requestId": .string("legacy-request"),
            "questions": .array([.object(["id": .string("q1"), "header": .string("Pick"), "question": .string("Which one?"), "options": .array([])])]),
        ])
        row.sourceItemId = row.item.id
        p.visibleTurnItems.insert(row, at: 0)
        p.runtimeRequests.append(try JSONValue.object([
            "id": .string("legacy-request"), "kind": .string("user_input"), "status": .string("resolved"),
            "answers": .object(["q1": .string("The first")]),
        ]).decode(as: RuntimeRequest.self))
        return p
    }
    for (suffix, pair) in [("stream", streamed), ("tool", tooled), ("stream_answered", answeredStreamed)] {
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

    /// The huge thread's window with one settled run of 600 commands, opened as a server sends it without and
    /// with deferred work (#26240).
    @Test func longWorkOpen() throws {
        for deferred in [false, true] {
            let (frame, threadId) = try longWorkFrame(work: 600, deferred: deferred)
            try measureFrameOpen(deferred ? "long_work_deferred" : "long_work_full", frame: frame, threadId: threadId)
        }
    }

    /// The first line of a streaming thought, which the live row draws on every update (`liveThoughtLine`).
    @Test func thoughtLine() {
        var text = "**Planning the change**\n\n"
        while text.utf8.count < 64_000 { text += "I need to check `Sources/App/Main.swift` and [the docs](https://example.com) before I *edit* it. " }
        let plain = String(text.dropFirst(26))
        var line = ""
        measure("thought_line_heading_64k", inner: 3, extra: ["bytes": text.utf8.count]) { line = liveThoughtLine(text) }
        measure("thought_line_64k", inner: 3, extra: ["bytes": plain.utf8.count]) { line = liveThoughtLine(plain) }
        #expect(!line.isEmpty)
    }

    /// A message that links 800 files of the same name, each told apart by its package folder (#34340).
    @Test func fileLinkLabels() {
        let paths = (0..<800).map { "/repo/packages/p\($0)/src/index.ts" }
        var suffixes: [String: String] = [:]
        measure("file_link_labels_800", runs: 5, extra: ["paths": paths.count]) { suffixes = FileLinks.parentSuffixes(paths) }
        #expect(suffixes[paths[3]] == "p3/src")
    }

    /// A reply that names 400 `$skill` tokens, checked against a provider with 500 skills (#29008).
    @Test func inlineSkills() {
        let skills = (0..<500).map { ServerProviderSkill(name: "skill-\($0)", path: "/skills/\($0)") }
        let text = (0..<400).map { "Use $skill-\(($0 * 7) % 500) here." }.joined(separator: " ")
        let doc = MarkdownDocument(parsing: text)
        var out = doc
        measure("inline_skills_500", runs: 5, extra: ["bytes": text.utf8.count]) { out = MarkdownInlineSkills.document(doc, skills: skills) }
        #expect(out != doc)
    }

    /// A subagent prompt that opens with comment divider lines but is no workflow script (#38368).
    @Test func workflowScriptCheck() {
        // The old pattern doubles its time about every 2 more slashes: 24 took 59 ms, 28 took 773 ms.
        let prompt = String(repeating: "/", count: 24) + "\nSummarize the release notes."
        var script = true
        measure("workflow_script_dividers", runs: 5, extra: ["bytes": prompt.utf8.count]) {
            script = WorkflowOpening.isScript(role: "user", text: prompt, workflowScript: nil)
        }
        #expect(!script)
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

    /// Redesign's extra main-thread work on every update of the open thread (`ThreadSession.setCost`): the gallery's
    /// image collection and the cost estimate, on the bounded window (`_open`, 57 rows, 900 runs) and the fully
    /// loaded thread (`_full`, 5,700 rows).
    @Test func redesignOpenThreadUpdate() throws {
        for (name, window) in [("open", 3), ("full", 300)] {
            let (p, _, tool) = try streamingProjection(copies: 300, window: window)
            var images = 0
            measure("redesign_update_gallery_\(name)_uncached", runs: 9, extra: ["rows": p.visibleTurnItems.count]) {
                images = ThreadImageGallery.collect(p, agent: "Main").images.count
            }
            // What the open thread pays since 2026-11-22: one tool row changed since the last update.
            let item = p.visibleTurnItems[tool].item
            let flips = try ["2026-01-02T00:00:01.000Z", "2026-01-02T00:00:02.000Z"].map { at in
                var q = p
                q.visibleTurnItems[tool].item = try replacing(item, ["updatedAt": .string(at)])
                return q
            }
            let cache = ThreadImageGallery.CollectCache()
            var k = 0
            measure("redesign_update_gallery_\(name)", runs: 9, extra: ["rows": p.visibleTurnItems.count]) {
                k += 1
                images = ThreadImageGallery.collect(flips[k % 2], agent: "Main", cache: cache).images.count
            }
            #expect(ThreadImageGallery.collect(flips[0], agent: "Main", cache: cache) == ThreadImageGallery.collect(flips[0], agent: "Main"))
            var models = 0
            measure("redesign_update_cost_\(name)_uncached", runs: 9, extra: ["runs": p.runs.count, "nodes": p.nodes.count]) {
                models = ThreadCostEstimate.own(p).models.count
            }
            let memo = ThreadCostEstimate.OwnMemo()
            measure("redesign_update_cost_\(name)", runs: 9, extra: ["runs": p.runs.count, "nodes": p.nodes.count]) {
                k += 1
                models = memo.own(flips[k % 2]).models.count
            }
            #expect(images >= 0 && models >= 0)
        }
    }

    /// The reducer's share of one streamed word on the `huge_full` thread (5,700 rows, 900 runs), which runs off the
    /// main thread for every token: `turn-item.updated` for the streaming answer through `ThreadReducer.apply`.
    @Test func hugeThreadReduceStream() throws {
        let (p, answer, _) = try streamingProjection(copies: 300, window: 300)
        var reducer = ThreadReducer(threadId: p.thread.id)
        reducer.applySnapshot(ThreadDetailSnapshot(snapshotSequence: 1, projection: p))
        let item = p.visibleTurnItems[answer].item
        let text = item.text
        var sequence = 1
        let events = try (0..<2).map { i in
            ThreadEvent(id: "e\(i)", type: "turn-item.updated", threadId: p.thread.id, runId: item.runId, occurredAt: "2026-01-02T00:00:00.000Z",
                        payload: .turnItem(try replacing(item, ["text": .string(text + String(repeating: " word", count: i + 1))])))
        }
        measure("huge_reduce_stream", runs: 9, inner: 5, extra: ["rows": p.visibleTurnItems.count]) {
            sequence += 1
            reducer.apply([.event(sequence: sequence, event: events[sequence % 2])])
        }
        #expect(reducer.projection?.visibleTurnItems.count == p.visibleTurnItems.count)
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

    /// Work every shell change or open-thread update repeats at the M10 load plus 1,000 archived threads: finding a
    /// thread by id (`[ThreadShell].index(of:)`, 0.47 ms through `first(where:)`, which copies each 1.8 KB shell) and
    /// rescoping the merged shell after one thread changed.
    @MainActor @Test func shellScans() {
        var snapshot = SidebarLoadTests.loadSnapshot()
        snapshot.archivedThreads = snapshot.threads.prefix(1_000).enumerated().map { i, t in
            var a = t
            a.id = ThreadId("archived-\(i)")
            return a
        }
        let missing = ThreadId("missing")
        var found: ThreadShell?
        measure("shell_thread_by_id_2580", inner: 50, extra: ["threads": 2_580]) { found = snapshot.thread(missing) }
        #expect(found == nil && snapshot.thread(snapshot.archivedThreads[999].id) != nil)
        var merged = MergedShell()
        merged.set(snapshot, environmentId: "env")
        var k = 0
        measure("shell_merge_one_change_2580", inner: 5, extra: ["threads": 2_580]) {
            k += 1
            snapshot.threads[1_450].title = "renamed \(k)"
            merged.set(snapshot, environmentId: "env")
        }
        #expect(merged.merged(order: ["env"])?.threads[1_450].title == "renamed \(k)")
    }

    /// The sidebar at the M10 load's 1,580 threads with the settled shelf open: a hinted one-thread rename, a
    /// minute's clock step and the settled shelf opening or closing, each with the layout that follows.
    @MainActor @Test func sidebarUpdates() {
        do {
            var now = SidebarPreview.referenceNow
            var snap = SidebarLoadTests.loadSnapshot()
            let content = SidebarContentView()
            content.now = { now }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 780), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = content
            content.frame = NSRect(x: 0, y: 0, width: 320, height: 780)
            content.state.settledExpanded = true
            content.state.settledVisibleCount = 2_000
            content.setSnapshot(snap, animated: false)
            content.layoutSubtreeIfNeeded()
            let style = "classic"
            var flip = false
            measure("sidebar_rename_1580_\(style)", runs: 15) {
                flip.toggle()
                snap.threads[1_400].title = flip ? "Renamed on screen" : "Renamed again"
                content.setSnapshot(snap, animated: false, changedThreadIds: [snap.threads[1_400].id])
                content.layoutSubtreeIfNeeded()
            }
            measure("sidebar_tick_1580_\(style)", runs: 15) {
                now = now.addingTimeInterval(60)
                content.setSnapshot(snap, animated: false)
                content.layoutSubtreeIfNeeded()
            }
            measure("sidebar_shelf_1580_\(style)", runs: 9) {
                content.state.settledExpanded.toggle()
                content.layoutSubtreeIfNeeded()
            }
            window.contentView = nil
        }
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

    /// A long thread on screen in a window: 40 turns of the huge thread, every reply 6 KB of markdown and a little
    /// different, so no two rows share a parse. Opened, then scrolled to the top and back 300 pt per step as
    /// `--perf-scroll` does, then resized. Main-thread time per step (scroll, layout and display), with the row
    /// configures each pass made.
    @Test func timelineScroll() async throws {
        try await measureScroll("scroll_long", copies: 300, window: 40)
    }
}

/// A thread of `window` turns whose replies are each a different 6 KB of markdown.
@MainActor
private func longThreadProjection(copies: Int, window: Int) throws -> ThreadProjection {
    let reply = longReply(sections: 12)
    let (frame, threadId) = try syntheticThreadFrame(copies: copies, window: window, reply: reply)
    guard case .chunk(_, let values)? = try RPCFrame.decodeServer(frame).first else { throw CancellationError() }
    var reducer = ThreadReducer(threadId: ThreadId(threadId))
    reducer.apply([try values[0].decode(as: ThreadStreamItem.self)])
    var p = try #require(reducer.projection)
    for i in p.visibleTurnItems.indices where p.visibleTurnItems[i].item.type == .assistantMessage {
        p.visibleTurnItems[i].item = try replacing(p.visibleTurnItems[i].item, ["text": .string("Reply \(i) starts here.\n\n" + reply)])
    }
    return p
}

@MainActor
private func measureScroll(_ name: String, copies: Int, window turns: Int) async throws {
    let p = try longThreadProjection(copies: copies, window: turns)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let panel = ThreadPanelView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
    window.contentView = panel
    let openStart = ContinuousClock.now
    panel.setProjection(p, projectTitle: "demo-repo", workspaceRoot: nil)
    var open = milliseconds(ContinuousClock.now - openStart)
    open += await panel.model.rowsSettled()
    let openLayout = ContinuousClock.now
    window.layoutIfNeeded()
    window.displayIfNeeded()
    open += milliseconds(ContinuousClock.now - openLayout)
    let timeline = panel.timeline
    func emit(_ suffix: String, _ steps: [Double], _ extra: [String: Any] = [:]) {
        let sorted = steps.sorted()
        var line: [String: Any] = ["name": "\(name)_\(suffix)", "median_ms": sorted[sorted.count / 2], "min_ms": sorted[0],
                                   "max_ms": sorted[sorted.count - 1], "runs": sorted.count, "total_ms": steps.reduce(0, +),
                                   "timeline_rows": panel.model.items.count]
        line.merge(extra) { $1 }
        let data = try! JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])
        print("PERF " + String(decoding: data, as: UTF8.self))
    }
    emit("open", [open], ["created": timeline.createdRowViews, "configures": timeline.configureCount])
    let clip = timeline.scrollView.contentView
    func pass(_ suffix: String, up: Bool) {
        let configures = timeline.configureCount, created = timeline.createdRowViews
        var steps: [Double] = []
        for _ in 0..<400 {
            let maxY = max(0, (timeline.scrollView.documentView?.frame.height ?? 0) - clip.bounds.height)
            let y = min(maxY, max(0, clip.bounds.origin.y + (up ? -300 : 300)))
            let before = clip.bounds.origin.y
            if y == before { break }
            let start = ContinuousClock.now
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
            timeline.scrollView.reflectScrolledClipView(clip)
            window.layoutIfNeeded()
            window.displayIfNeeded()
            steps.append(milliseconds(ContinuousClock.now - start))
            if clip.bounds.origin.y == before { break }
        }
        emit(suffix, steps, ["configures": timeline.configureCount - configures, "created": timeline.createdRowViews - created,
                             "document": Int(timeline.scrollView.documentView?.frame.height ?? 0)])
    }
    pass("up_first", up: true)
    pass("down", up: false)
    pass("up_again", up: true)
    // Reading back: from the middle, six steps up and six back down, ten times, as a reader checks something above.
    clip.scroll(to: NSPoint(x: 0, y: 60_000))
    timeline.scrollView.reflectScrolledClipView(clip)
    window.layoutIfNeeded()
    window.displayIfNeeded()
    do {
        let configures = timeline.configureCount
        var steps: [Double] = []
        for _ in 0..<10 {
            for up in [true, false] {
                for _ in 0..<6 {
                    let start = ContinuousClock.now
                    clip.scroll(to: NSPoint(x: 0, y: clip.bounds.origin.y + (up ? -300 : 300)))
                    timeline.scrollView.reflectScrolledClipView(clip)
                    window.layoutIfNeeded()
                    window.displayIfNeeded()
                    steps.append(milliseconds(ContinuousClock.now - start))
                }
            }
        }
        emit("back_and_forth", steps, ["configures": timeline.configureCount - configures])
    }
    // CW_BENCH_PROFILE=scroll repeats the passes for about 10 s, for `sample`.
    let profile = ProcessInfo.processInfo.environment["CW_BENCH_PROFILE"]
    if profile == "scroll" {
        let until = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < until { pass("profile_down", up: false); pass("profile_up", up: true) }
    }
    // A live resize: the window narrows by 8 pt a step to 900 pt, then widens back.
    var resize: [Double] = []
    let configures = timeline.configureCount
    let widths = Array(stride(from: 1192, through: 900, by: -8)) + Array(stride(from: 908, through: 1200, by: 8))
    for w in profile == "resize" ? Array(repeating: widths, count: 25).flatMap { $0 } : widths {
        let start = ContinuousClock.now
        window.setContentSize(NSSize(width: CGFloat(w), height: 800))
        window.layoutIfNeeded()
        window.displayIfNeeded()
        resize.append(milliseconds(ContinuousClock.now - start))
    }
    emit("resize", resize, ["configures": timeline.configureCount - configures])
    // A reply streams at the bottom while the reader sits near the top: one word per update.
    var live = p
    let run = try #require(live.runs.indices.max { live.runs[$0].ordinal < live.runs[$1].ordinal })
    live.runs[run].status = .running
    live.runs[run].completedAt = nil
    let answer = try #require(live.visibleTurnItems.lastIndex { $0.item.type == .assistantMessage })
    live.visibleTurnItems[answer].item = try replacing(live.visibleTurnItems[answer].item, ["streaming": .bool(true), "status": .string("running")])
    panel.setProjection(live, projectTitle: "demo-repo", workspaceRoot: nil)
    await panel.model.rowsSettled()
    window.layoutIfNeeded()
    clip.scroll(to: NSPoint(x: 0, y: 1200))
    timeline.scrollView.reflectScrolledClipView(clip)
    window.layoutIfNeeded()
    window.displayIfNeeded()
    let text = live.visibleTurnItems[answer].item.text
    var streamed: [Double] = []
    let streamConfigures = timeline.configureCount
    for k in 1...(profile == "stream" ? 3_000 : 14) {
        var next = live
        next.visibleTurnItems[answer].item = try replacing(next.visibleTurnItems[answer].item, ["text": .string(text + String(repeating: " word", count: k))])
        let start = ContinuousClock.now
        panel.setProjection(next, projectTitle: "demo-repo", workspaceRoot: nil)
        var main = milliseconds(ContinuousClock.now - start)
        main += await panel.model.rowsSettled()
        let layout = ContinuousClock.now
        window.layoutIfNeeded()
        window.displayIfNeeded()
        main += milliseconds(ContinuousClock.now - layout)
        if k > 2 { streamed.append(main) }
    }
    #expect(clip.bounds.origin.y < 2000)
    emit("stream_offscreen", streamed, ["configures": timeline.configureCount - streamConfigures])
    window.close()
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
