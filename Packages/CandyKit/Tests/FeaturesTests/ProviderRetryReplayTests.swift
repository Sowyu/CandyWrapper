import AppKit
import Foundation
import Testing
import T3Protocol
import T3Store
@testable import Features

/// Work items replayed into a recorded turn (09-reasoning-tools.jsonl) through the reducer, the
/// row pipeline and the timeline. The provider retry is one `error` item with `retry` that the
/// server updates in place (failure.ts:212-266, ClaudeAdapterV2.ts:6054-6095).
///
/// A collapsed live row shows each entry once. An expanded live group lists every entry of the
/// group under the header, the running one included, as T3 does (MessagesTimeline.logic.ts:1501-1512,
/// MessagesTimeline.logic.test.ts:3215-3245); that is the second "Retrying provider" line the user saw.
@MainActor
struct ProviderRetryReplayTests {
    static let itemId = "turn-item:provider:claudeAgent:native-item:replayed"

    /// `values[24]` is a running `command_execution`; its envelope carries the replayed item.
    static func event(from template: [String: Any], sequence: Int, _ edit: (inout [String: Any]) -> Void) -> [String: Any] {
        var value = template
        var event = value["event"] as! [String: Any]
        var p = event["payload"] as! [String: Any]
        p["id"] = itemId
        p["nativeItemRef"] = NSNull()
        p["ordinal"] = 1_000_090
        p.removeValue(forKey: "input")
        edit(&p)
        p["completedAt"] = p["status"] as? String == "running" ? NSNull() : p["updatedAt"]
        event["payload"] = p
        event["id"] = "event:replayed:\(sequence)"
        value["event"] = event
        value["sequence"] = sequence
        return value
    }

    static func retry(_ attempt: Int, _ status: String) -> (inout [String: Any]) -> Void {
        { p in
            p["type"] = "error"
            p["status"] = status
            p["title"] = status == "running" ? "Provider retry" : "Provider recovered"
            p["failure"] = ["class": "provider_error", "message": "Overloaded", "code": NSNull(), "retryable": true]
            p["retry"] = ["attempt": attempt, "maxAttempts": 10, "retryDelayMs": 2_000]
        }
    }

    /// One running then completed update per work item type the live row can hold.
    static let types: [(String, [String: Any])] = [
        ("reasoning", ["text": "Checking the repo layout first."]),
        ("command_execution", ["input": "ls -la"]),
        ("file_change", ["fileName": "notes.md", "changes": [["path": "notes.md"]]]),
        ("file_search", ["pattern": "*.md"]),
        ("web_search", ["patterns": ["swift testing"]]),
        ("dynamic_tool", ["toolName": "Read", "input": ["file_path": "README.md"]]),
        ("approval_request", ["prompt": "Run ls?", "requestKind": "command"]),
        ("user_input_request", [:]),
        ("subagent", [:]),
        ("checkpoint", [:]),
        ("todo_list", [:]),
    ]

    /// The entry ids each collapsed row shows on its own line. Expanded bodies are left out.
    static func shown(_ row: TimelineRow) -> [String] {
        switch row.kind {
        case .work(let entries, false, _): entries.map(\.id)
        case .workLive(let entry, _, _, let expanded, _, let thought):
            // A thought that is itself the latest entry reads "Thinking" on the status line.
            [entry.id] + (thought.map { !expanded && $0.id != entry.id ? [$0.id] : [] } ?? [])
        case .workToggle(let t) where t.hiddenCount == 1: [t.groupId]
        default: []
        }
    }

    /// Replays `updates` after the first `cut` stream values and checks every step, collapsed and
    /// with the live group open. Returns the rows after each update.
    static func replay(cut: Int, _ updates: [(inout [String: Any]) -> Void]) async throws -> [[TimelineRow]] {
        let all = try LiveTurnReplayTests.values("09-reasoning-tools.jsonl", streamed: false).map(\.value)
        var stream = all.prefix(cut).map { $0 }
        for (i, edit) in updates.enumerated() { stream.append(event(from: all[24], sequence: 20_000_000 + i, edit)) }
        var reducer = ThreadReducer(threadId: ThreadId("edd9384e-8da3-40c4-93cc-1fbc661bbad0"))
        let panel = ThreadPanelView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        var out: [[TimelineRow]] = []
        for (n, value) in stream.enumerated() {
            _ = reducer.apply([try JSONDecoder().decode(ThreadStreamItem.self, from: JSONSerialization.data(withJSONObject: value))])
            guard n >= cut, let p = reducer.projection else { continue }
            panel.setProjection(p, projectTitle: "demo-repo", workspaceRoot: nil)
            await panel.model.rowsSettled()
            panel.layoutSubtreeIfNeeded()
            let rows = panel.model.items.map(\.row)
            let label = "cut \(cut) step \(n)"
            var seen: [String: Int] = [:]
            for row in rows { for id in shown(row) { seen[id, default: 0] += 1 } }
            #expect(seen.filter { $0.value > 1 }.isEmpty, "\(label): shown twice \(seen.filter { $0.value > 1 }) in \(rows.map(\.id))")
            #expect(panel.timeline.layoutProblems().isEmpty, "\(label): \(panel.timeline.layoutProblems())")
            out.append(rows)
            // Open the live group: T3 lists the group under its header, nothing else repeats.
            if let live = rows.first(where: { if case .workLive = $0.kind { true } else { false } }),
               case .workLive(_, let grouped, let groupId, false, _, _) = live.kind {
                panel.model.toggleGroup(groupId)
                await panel.model.rowsSettled()
                panel.layoutSubtreeIfNeeded()
                let open = panel.model.items.map(\.row)
                let bodies = open.filter { $0.id == "\(groupId):details" }
                #expect(bodies.count == 1, "\(label) open: \(open.map(\.id))")
                if case .work(let entries, true, _)? = bodies.first?.kind { #expect(entries == grouped, "\(label) open") }
                #expect(open.count == rows.count + 1, "\(label) open: \(open.map(\.id))")
                #expect(panel.timeline.layoutProblems().isEmpty, "\(label) open: \(panel.timeline.layoutProblems())")
                panel.model.toggleGroup(groupId)
                await panel.model.rowsSettled()
            }
        }
        return out
    }

    @Test func retrySequenceShowsEachEntryOnce() async throws {
        // 16: right after the run started. 27: after a finished command, so the live group holds two entries.
        for cut in [16, 27] {
            let steps = try await Self.replay(cut: cut, [Self.retry(5, "running"), Self.retry(6, "running"), Self.retry(6, "completed")])
            let labels = steps.map { rows in
                rows.compactMap { row -> String? in
                    guard case .workLive(let entry, _, _, _, _, _) = row.kind, entry.id == Self.itemId else { return nil }
                    return entry.label
                }
            }
            #expect(labels == [["Retrying provider (5/10)"], ["Retrying provider (6/10)"], ["Provider recovered (6/10 retries)"]], "cut \(cut)")
        }
    }

    @Test func everyWorkTypeShowsOnce() async throws {
        for (type, fields) in Self.types {
            for cut in [16, 27] {
                _ = try await Self.replay(cut: cut, ["running", "completed"].map { status in
                    { p in
                        p["type"] = type
                        p["status"] = status
                        for (k, v) in fields { p[k] = v }
                    }
                })
            }
        }
    }
}
