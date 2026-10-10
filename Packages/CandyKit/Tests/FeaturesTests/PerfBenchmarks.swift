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
private func longReply() -> String {
    var s = "# Report\n\n"
    for i in 1...120 {
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

    @Test func markdownLayout() {
        let text = longReply()
        var height: CGFloat = 0
        measure("markdown_parse", inner: 5, extra: ["bytes": text.utf8.count]) {
            _ = MarkdownDocument(parsing: text)
        }
        let doc = MarkdownDocument(parsing: text)
        measure("markdown_layout", extra: ["blocks": doc.blocks.count]) {
            height = MarkdownLayout(document: doc, width: 680).height
        }
        #expect(height > 1000)
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
}
