import Foundation
import Testing
import T3Protocol
@testable import Features

/// `presentPendingBackgroundWork` (threadExecution.ts:281-357), the background work banner's text.
struct BackgroundWorkBannerTests {
    private func task(_ kind: BackgroundTaskKind, _ description: String? = nil, child: String? = nil, awaited: Bool = false) -> PendingBackgroundTask {
        PendingBackgroundTask(taskId: UUID().uuidString, description: description, kind: kind, childThreadId: child.map { ThreadId($0) }, awaited: awaited)
    }

    @Test func titlesOneTask() {
        #expect(BackgroundWorkPresentation.present([]) == nil)
        #expect(BackgroundWorkPresentation.present([task(.command, "npm test")])?.title == "Running: npm test")
        #expect(BackgroundWorkPresentation.present([task(.command, "  ")])?.title == "Running a command")
        #expect(BackgroundWorkPresentation.present([task(.subagent, "Subagent: Fix the bug", child: "c1")])?.title == "Waiting on subagent Fix the bug")
        #expect(BackgroundWorkPresentation.present([task(.subagent)])?.title == "Waiting on a subagent")
        #expect(BackgroundWorkPresentation.present([task(.monitor, "CI", awaited: true)])?.title == "CI")
        // 3669: a monitor the agent doesn't wait on reads as running, like a dev server.
        #expect(BackgroundWorkPresentation.present([task(.monitor, "CI")])?.title == "Running: CI")
        // A server before 3655 marks nothing awaited, so its monitors wait as on 3473.
        #expect(BackgroundWorkPresentation.present([task(.monitor, "CI")], awaitedMarked: false)?.title == "CI")
        #expect(BackgroundWorkPresentation.present([task(BackgroundTaskKind(rawValue: "future"))])?.title == "Waiting on a background task")
        // Commands don't hold completion, so their dot stays still.
        #expect(BackgroundWorkPresentation.present([task(.command)])?.waiting == false)
    }

    @Test func countsSeveralTasksSubagentsFirst() throws {
        let value = try #require(BackgroundWorkPresentation.present([task(.command, "a"), task(.subagent, "b", child: "c"), task(.command, "d"), task(.monitor, awaited: true)]))
        #expect(value.title == "Waiting on 1 subagent, 2 commands and 1 monitor")
        #expect(value.items.map(\.label) == ["b", "a", "d", "monitor"])
        #expect(value.items.map(\.childThreadId) == [ThreadId("c"), nil, nil, nil])
        #expect(BackgroundWorkPresentation.present([task(.command), task(.command)])?.title == "Running 2 commands")
    }

    @Test func newestActivityWinsAndOneTaskKeepsItsOwnDurationAndChild() throws {
        func item(_ id: String, taskId: String, progress: String, updated: String) throws -> TurnItem {
            try TurnItem(json: .object(["id": .string(id), "type": .string("subagent"), "threadId": .string("t"),
                "ordinal": .number(1), "status": .string("running"), "nativeItemRef": .object(["nativeId": .string(taskId)]),
                "progress": .string(progress), "childThreadId": .string("child"),
                "startedAt": .string("2026-10-28T00:00:00Z"), "updatedAt": .string(updated)]))
        }
        let tasks = [PendingBackgroundTask(taskId: "a", description: "First", kind: .subagent),
                     PendingBackgroundTask(taskId: "b", description: "Second", kind: .subagent)]
        let items = [try item("one", taskId: "a", progress: "Earlier", updated: "2026-10-28T00:00:01Z"),
                     try item("two", taskId: "b", progress: "  Reading\n files  ", updated: "2026-10-28T00:00:02Z")]
        let multiple = BackgroundWorkPresentation.activity(try #require(BackgroundWorkPresentation.present(tasks)), turnItems: items)
        #expect(multiple.detail == "Second: Reading files")
        #expect(multiple.startedAt == nil && multiple.childThreadId == nil)
        let one = BackgroundWorkPresentation.activity(try #require(BackgroundWorkPresentation.present([tasks[1]])), turnItems: items)
        #expect(one.title == "Waiting on Second" && one.detail == "Reading files")
        #expect(one.startedAt == "2026-10-28T00:00:00Z" && one.childThreadId == "child")
        #expect(!one.commandsOnly)
    }

    /// Redesign's indicator drops the titles.
    @Test func shortTitles() throws {
        func short(_ tasks: [PendingBackgroundTask]) throws -> String { BackgroundWorkPresentation.shortTitle(try #require(BackgroundWorkPresentation.present(tasks))) }
        #expect(try short([task(.subagent, "Subagent: Fix the bug", child: "c1")]) == "Waiting on subagent")
        #expect(try short([task(.subagent, "a"), task(.subagent, "b")]) == "Waiting on 2 subagents")
        #expect(try short([task(.command, "npm test")]) == "Running a command")
        #expect(try short([task(.subagent, "a"), task(.command, "b")]) == "Waiting")
    }
}
