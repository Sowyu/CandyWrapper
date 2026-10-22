import Foundation
import Testing
import T3Protocol
@testable import Features

/// `presentPendingBackgroundWork` (threadExecution.ts:281-357), the background work banner's text.
struct BackgroundWorkBannerTests {
    private func task(_ kind: BackgroundTaskKind, _ description: String? = nil, child: String? = nil) -> PendingBackgroundTask {
        PendingBackgroundTask(taskId: UUID().uuidString, description: description, kind: kind, childThreadId: child.map { ThreadId($0) })
    }

    @Test func titlesOneTask() {
        #expect(BackgroundWorkPresentation.present([]) == nil)
        #expect(BackgroundWorkPresentation.present([task(.command, "npm test")])?.title == "Running: npm test")
        #expect(BackgroundWorkPresentation.present([task(.command, "  ")])?.title == "Running a command")
        #expect(BackgroundWorkPresentation.present([task(.subagent, "Subagent: Fix the bug", child: "c1")])?.title == "Waiting on subagent Fix the bug")
        #expect(BackgroundWorkPresentation.present([task(.subagent)])?.title == "Waiting on a subagent")
        #expect(BackgroundWorkPresentation.present([task(.monitor, "CI")])?.title == "CI")
        #expect(BackgroundWorkPresentation.present([task(BackgroundTaskKind(rawValue: "future"))])?.title == "Waiting on a background task")
        // Commands don't hold completion, so their dot stays still.
        #expect(BackgroundWorkPresentation.present([task(.command)])?.waiting == false)
    }

    @Test func countsSeveralTasksSubagentsFirst() throws {
        let value = try #require(BackgroundWorkPresentation.present([task(.command, "a"), task(.subagent, "b", child: "c"), task(.command, "d"), task(.monitor)]))
        #expect(value.title == "Waiting on 1 subagent, 2 commands and 1 monitor")
        #expect(value.items.map(\.label) == ["b", "a", "d", "monitor"])
        #expect(value.items.map(\.childThreadId) == [ThreadId("c"), nil, nil, nil])
        #expect(BackgroundWorkPresentation.present([task(.command), task(.command)])?.title == "Running 2 commands")
    }
}
