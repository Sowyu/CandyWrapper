import AppKit
import Foundation
import Testing
import T3Protocol
import T3Store
@testable import Features

/// A live turn replayed one stream item at a time through the reducer, the row pipeline, the view
/// model and the timeline, with every incremental path the app takes while text streams. After
/// each step the rows must equal a derive from scratch, and no reasoning item may show twice.
@MainActor
struct LiveTurnReplayTests {
    /// One applied stream item: the projection after it and what the reducer said changed.
    struct Step {
        var projection: ThreadProjection
        var changes: ThreadChangeSet
    }

    /// The stream items of every `subscribeThread` in a transcript, as JSON values in arrival order.
    /// `streamed`: each settled answer and thought first arrives the way T3 streams it, as growing
    /// text with `streaming: true` (assistantStreaming.ts:92-129, ClaudeAdapterV2.ts:4886-4925): an
    /// answer as `message.updated` then `turn-item.updated`, a thought as `turn-item.updated` alone.
    static func values(_ transcript: String, streamed: Bool) throws -> [(subscription: String, threadId: String, value: [String: Any])] {
        let url = SidebarPreview.repo.appendingPathComponent("fixtures/transcripts/\(transcript)")
        var threadOf: [String: String] = [:]
        var raw: [(String, [String: Any])] = []
        for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
            guard let record = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  record["kind"] as? String == "ws" else { continue }
            let bodies = (record["body"] as? [[String: Any]]) ?? [(record["body"] as? [String: Any]) ?? [:]]
            for body in bodies {
                if record["dir"] as? String == "send", body["tag"] as? String == "orchestration.subscribeThread",
                   let id = body["id"] as? String, let threadId = (body["payload"] as? [String: Any])?["threadId"] as? String {
                    threadOf[id] = threadId
                } else if body["_tag"] as? String == "Chunk", let id = body["requestId"] as? String, threadOf[id] != nil,
                          let values = body["values"] as? [[String: Any]] {
                    raw += values.map { (id, $0) }
                }
            }
        }
        // The settled answer items by id, so a streamed answer can send its turn item with each message update.
        var answerItems: [String: [String: Any]] = [:]
        for (_, value) in raw {
            if let event = value["event"] as? [String: Any], event["type"] as? String == "turn-item.updated",
               let p = event["payload"] as? [String: Any], p["type"] as? String == "assistant_message", let id = p["id"] as? String {
                answerItems[id] = p
            }
        }
        var out: [(String, String, [String: Any])] = []
        var sequence = 10_000_000
        func emit(_ id: String, _ value: [String: Any]) {
            var value = value
            if value["kind"] as? String == "event" { value["sequence"] = sequence; sequence += 1 }
            out.append((id, threadOf[id]!, value))
        }
        func streamingCopy(_ value: [String: Any], text: String, item: Bool) -> [String: Any] {
            var value = value, event = value["event"] as! [String: Any], p = event["payload"] as! [String: Any]
            p["text"] = text
            p["streaming"] = true
            if item { p["status"] = "running"; p["completedAt"] = NSNull() }
            event["payload"] = p
            value["event"] = event
            return value
        }
        for (id, value) in raw {
            guard streamed, let event = value["event"] as? [String: Any], let p = event["payload"] as? [String: Any],
                  p["streaming"] as? Bool == false, let text = p["text"] as? String, !text.isEmpty else { emit(id, value); continue }
            let type = event["type"] as? String
            if type == "message.updated", p["role"] as? String == "assistant", let messageId = p["id"] as? String,
               let item = answerItems["turn-item:" + messageId.replacingOccurrences(of: "message:", with: "", options: .anchored)] {
                var itemValue = value
                var itemEvent = event
                itemEvent["type"] = "turn-item.updated"
                itemEvent["payload"] = item
                itemValue["event"] = itemEvent
                for prefix in Self.prefixes(text) {
                    emit(id, streamingCopy(value, text: prefix, item: false))
                    emit(id, streamingCopy(itemValue, text: prefix, item: true))
                }
            } else if type == "turn-item.updated", p["type"] as? String == "reasoning" {
                for prefix in Self.prefixes(text) { emit(id, streamingCopy(value, text: prefix, item: true)) }
            }
            emit(id, value)
        }
        return out
    }

    /// Growing cuts of `text` at word ends, about every 40 characters.
    static func prefixes(_ text: String) -> [String] {
        var out: [String] = []
        var last = text.startIndex
        for i in text.indices where text[i] == " " && text.distance(from: last, to: i) >= 40 {
            out.append(String(text[..<i]))
            last = i
        }
        return out
    }

    /// Applies the values `batch` at a time, as the app's pacer merges what arrived between frames.
    static func steps(_ transcript: String, streamed: Bool, batch: Int) throws -> [Step] {
        var reducers: [String: ThreadReducer] = [:]
        var out: [Step] = []
        var pending: [ThreadStreamItem] = []
        var pendingSubscription: String?
        func flush() {
            guard let id = pendingSubscription, !pending.isEmpty else { return }
            let changes = reducers[id]!.apply(pending)
            pending = []
            if changes.projectionChanged, let p = reducers[id]!.projection { out.append(Step(projection: p, changes: changes)) }
        }
        for (id, threadId, value) in try values(transcript, streamed: streamed) {
            if reducers[id] == nil { reducers[id] = ThreadReducer(threadId: ThreadId(threadId)) }
            if pendingSubscription != id { flush(); pendingSubscription = id }
            pending.append(try JSONDecoder().decode(ThreadStreamItem.self, from: JSONSerialization.data(withJSONObject: value)))
            if pending.count >= batch { flush() }
        }
        flush()
        return out
    }

    /// The reasoning entries a row shows on its own line. Expanded group bodies repeat their
    /// group's entries on purpose and are left out.
    static func shownReasoning(_ row: TimelineRow) -> [String] {
        switch row.kind {
        case .work(let entries, false, _): entries.filter { $0.itemType == .reasoning }.map(\.id)
        case .workLive(_, let entries, _, false, _, _): entries.filter { $0.itemType == .reasoning }.map(\.id)
        default: []
        }
    }

    /// `offMain`: rows derive off the main thread, and a new update can land while a pass runs;
    /// the rows are compared every `settleEvery` steps, once the passes settled.
    static func check(_ transcript: String, streamed: Bool, batch: Int, offMain: Bool = false, settleEvery: Int = 1) async throws -> Int {
        let steps = try steps(transcript, streamed: streamed, batch: batch)
        let panel = ThreadPanelView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        if offMain { panel.model.backgroundRowsThreshold = 0 }
        var memo = TimelineRowsInput.Memo()
        var streamingSteps = 0
        for (n, step) in steps.enumerated() {
            let p = step.projection
            let label = "\(transcript) streamed \(streamed) batch \(batch) offMain \(offMain) step \(n)"
            // The entry memo against a fresh entry pass.
            let incremental = TimelineRowsInput.derive(projection: p, memo: &memo).input
            let fresh = TimelineRowsInput(projection: p)
            #expect(incremental.entries == fresh.entries, "\(label): entries")
            // The panel takes the same path the app does (ThreadSession.pull).
            let onlyText = step.changes.projectionChanged && step.changes.onlyStreamingText && !step.changes.reset
            if onlyText { streamingSteps += 1 }
            panel.setProjection(p, projectTitle: "demo-repo", workspaceRoot: nil, onlyStreamingText: onlyText)
            if n % settleEvery != 0, n != steps.count - 1 { continue }
            await panel.model.rowsSettled()
            panel.layoutSubtreeIfNeeded()
            let expected = TimelineRows.derive(fresh)
            let rows = panel.model.items.map(\.row)
            #expect(rows == expected, "\(label): rows \(rows.map(\.id)) expected \(expected.map(\.id))")
            #expect(panel.timeline.items == panel.model.items, "\(label): timeline items")
            let problems = panel.timeline.layoutProblems()
            #expect(problems.isEmpty, "\(label): \(problems)")
            var seen: [String: Int] = [:]
            for row in rows { for id in shownReasoning(row) { seen[id, default: 0] += 1 } }
            let twice = seen.filter { $0.value > 1 }.map(\.key)
            #expect(twice.isEmpty, "\(label): reasoning shown twice \(twice)")
        }
        return streamingSteps
    }

    @Test func recordedTurnsMatchAFullDeriveAtEveryStep() async throws {
        for transcript in ["02-turn.jsonl", "03-turn2.jsonl", "07-queue.jsonl", "09-reasoning-tools.jsonl"] {
            _ = try await Self.check(transcript, streamed: false, batch: 1)
        }
    }

    @Test func streamedTurnsMatchAFullDeriveAtEveryStep() async throws {
        for batch in [1, 2, 3] {
            let streaming = try await Self.check("09-reasoning-tools.jsonl", streamed: true, batch: batch)
            #expect(streaming > 10, "batch \(batch): the replay took the streaming fast paths \(streaming) times")
        }
        for settle in [1, 3] {
            _ = try await Self.check("09-reasoning-tools.jsonl", streamed: true, batch: 1, offMain: true, settleEvery: settle)
        }
    }

    /// An open live group whose entries are all thoughts shows them as T3's reasoning trace, not as a
    /// second one-line copy of the thought under the status line (MessagesTimeline.tsx:3447-3449).
    @Test func expandedThoughtGroupShowsTheTrace() async throws {
        let steps = try Self.steps("09-reasoning-tools.jsonl", streamed: true, batch: 1)
        let panel = ThreadPanelView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        var checked = 0
        for step in steps {
            panel.setProjection(step.projection, projectTitle: "demo-repo", workspaceRoot: nil)
            guard let live = panel.model.items.last(where: { if case .workLive = $0.row.kind { true } else { false } }),
                  case .workLive(_, let grouped, let groupId, false, _, _) = live.row.kind,
                  grouped.allSatisfy({ $0.itemType == .reasoning }) else { continue }
            panel.model.toggleGroup(groupId)
            panel.layoutSubtreeIfNeeded()
            let body = try #require(panel.model.items.first { $0.id == "\(groupId):details" })
            let view = try #require(panel.timeline.view(forRow: body.id) as? WorkRowView)
            #expect(view.traceOnly)
            #expect(view.frame.height > 24 + 8, "the trace holds the thought's text")
            #expect(panel.timeline.layoutProblems().isEmpty)
            panel.model.toggleGroup(groupId)
            checked += 1
        }
        #expect(checked > 0)
    }
}
