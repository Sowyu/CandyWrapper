import AppKit
import Testing
import T3Protocol
import T3Store
@testable import Features

/// The steer and queued markers above a user bubble (`UserMessageIntentMarker`,
/// MessagesTimeline.tsx:2395-2397, 2562-2603), on the recorded 07-queue thread.
@MainActor
struct UserIntentMarkerTests {
    @Test func presentationFollowsTheIntent() {
        #expect(UserIntentMarkerView.presentation(nil) == nil)
        #expect(UserIntentMarkerView.presentation(.turnStart) == nil)
        #expect(UserIntentMarkerView.presentation(.steer)?.label == "Steer")
        #expect(UserIntentMarkerView.presentation(.steer)?.tooltip == "Steered the active turn")
        #expect(UserIntentMarkerView.presentation(.promotedQueuedToSteer)?.tooltip == "Originally queued, then promoted to steer the active turn")
        // "From queue" left in 5cda25e72b.
        #expect(UserIntentMarkerView.presentation(.queuedTurn) == nil)
    }

    @Test func steeredRowsDrawTheMarkerAboveTheBubble() throws {
        let projection = try #require(try ThreadPreview.projections(transcript: "07-queue.jsonl").first)
        let items = TimelineRows.derive(TimelineRowsInput(projection: projection)).map { TimelineItem(row: $0) }
        let t = ThreadTimelineTests.timeline(items)
        let users = items.filter { if case .message(let m, _, _, _, _, _) = $0.row.kind { return m.role == .user }; return false }
        #expect(users.count == 3)
        // The long answer pushes the prompts above the fold; they all sit near the top.
        t.scroll(toFraction: 0)
        let width = t.laneFrame.width
        var heights: [CGFloat] = []
        for item in users {
            let view = try #require(t.view(forRow: item.id) as? UserMessageRowView, "\(item.id) has no view")
            // The same message without an intent is exactly the marker line and its gap shorter.
            var plain = item
            guard case .message(var m, let p, let a, let b, let c, let d) = plain.row.kind else { continue }
            m.inputIntent = nil
            plain.row.kind = .message(m, projectedItem: p, showAssistantMeta: a, showAssistantCopyButton: b, assistantCopyStreaming: c, turnDiffSummary: d)
            let marked = view.height(forWidth: width)
            view.configure(plain)
            heights.append(marked - view.height(forWidth: width))
            view.configure(item)
        }
        #expect(heights == [0, 16, 16])
        #expect(t.layoutProblems().isEmpty)
    }
}
