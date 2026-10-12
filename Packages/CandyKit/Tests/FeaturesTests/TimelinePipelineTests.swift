import AppKit
import Foundation
import Testing
import T3Protocol
import T3Store
@testable import Features

/// Every projection a recorded stream goes through, one item at a time.
private func steps(_ transcript: String) throws -> [ThreadProjection] {
    let url = SidebarPreview.repo.appendingPathComponent("fixtures/transcripts/\(transcript)")
    var threadOf: [String: ThreadId] = [:]
    var reducers: [String: ThreadReducer] = [:]
    var out: [ThreadProjection] = []
    for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
        guard let record = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              record["kind"] as? String == "ws", let body = record["body"] as? [String: Any] else { continue }
        if record["dir"] as? String == "send", body["tag"] as? String == "orchestration.subscribeThread",
           let id = body["id"] as? String, let threadId = (body["payload"] as? [String: Any])?["threadId"] as? String {
            threadOf[id] = ThreadId(threadId)
            reducers[id] = ThreadReducer(threadId: ThreadId(threadId))
        } else if body["_tag"] as? String == "Chunk", let id = body["requestId"] as? String, reducers[id] != nil,
                  let values = body["values"] as? [Any] {
            for value in values {
                let item = try JSONDecoder().decode(ThreadStreamItem.self, from: JSONSerialization.data(withJSONObject: value))
                if !reducers[id]!.apply([item]).isEmpty, let p = reducers[id]!.projection { out.append(p) }
            }
        }
    }
    return out
}

/// The row pipeline off the main thread and on it give the same rows, and the timeline stays
/// consistent under the change hints it gets.
@MainActor
struct TimelinePipelineTests {
    @Test func offMainUpdatesMatchSynchronousOnes() async throws {
        for transcript in ["02-turn.jsonl", "03-turn2.jsonl", "07-queue.jsonl"] {
            let projections = try steps(transcript)
            #expect(projections.count > 10)
            let panel = ThreadPanelView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
            panel.model.backgroundRowsThreshold = 0
            let reference = ThreadViewModel()
            reference.backgroundRowsThreshold = .max
            for (step, p) in projections.enumerated() {
                panel.setProjection(p, projectTitle: "demo-repo", workspaceRoot: nil)
                reference.setProjection(p)
                await panel.model.rowsSettled()
                panel.layoutSubtreeIfNeeded()
                #expect(panel.model.items.map(\.row) == reference.items.map(\.row), "\(transcript) step \(step)")
                #expect(panel.timeline.items == panel.model.items)
                let problems = panel.timeline.layoutProblems()
                #expect(problems.isEmpty, "\(transcript) step \(step): \(problems)")
            }
        }
    }

    /// Updates that arrive while a pass runs off the main thread collapse into one newer pass,
    /// and the result is the newest state.
    @Test func updatesDuringAPassEndOnTheNewestState() async throws {
        let projections = try steps("02-turn.jsonl")
        let model = ThreadViewModel()
        model.backgroundRowsThreshold = 0
        for p in projections { model.setProjection(p) }
        await model.rowsSettled()
        let reference = ThreadViewModel()
        reference.setProjection(projections.last)
        #expect(model.items.map(\.row) == reference.items.map(\.row))
    }

    /// Stress regression (out-of-order seed 2, bounded seed 1): the prompt's row arrived but its
    /// message did not (a bounded snapshot keeps only recent messages; a reconnect can lose the
    /// message event), and the optimistic copy showed under it a second time. T3 drops the
    /// optimistic copy once the row exists (ChatView.tsx:1751-1766, session-logic.ts:772-802).
    @Test func anOptimisticPromptShowsOnceWhenItsRowArrivesWithoutItsMessage() throws {
        var projection = try #require(try steps("02-turn.jsonl").last)
        let prompt = try #require(projection.visibleTurnItems.first { $0.item.type == .userMessage }?.item)
        let id = try #require(prompt.messageId)
        projection.messages.removeAll { $0.id == id }
        let model = ThreadViewModel()
        model.setProjection(projection)
        model.optimisticMessages = [ChatMessage(id: id, role: .user, text: prompt.text, createdAt: "2026-01-01T00:00:00.000Z")]
        #expect(model.items.filter { $0.row.message?.id == id }.count == 1)
    }

    /// A late result for the thread the view left is dropped.
    @Test func switchingThreadsDropsTheOldThreadsRows() async throws {
        let all = try ThreadPreview.projections()
        let a = try #require(all.max { $0.visibleTurnItems.count < $1.visibleTurnItems.count })
        let b = try #require(all.first { $0.thread.id != a.thread.id })
        let model = ThreadViewModel()
        model.backgroundRowsThreshold = a.visibleTurnItems.count
        model.setProjection(a)  // off the main thread
        model.setProjection(b)  // below the threshold: on it, at once
        await model.rowsSettled()
        try await Task.sleep(for: .milliseconds(50))
        let reference = ThreadViewModel()
        reference.setProjection(b)
        #expect(model.items.map(\.row) == reference.items.map(\.row))
    }
}
