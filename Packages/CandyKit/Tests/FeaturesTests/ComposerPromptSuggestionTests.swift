import Foundation
import Testing
@testable import Features
import T3Protocol

/// Prompt suggestions (#28047, #33706 at 4928, usePromptSuggestion.test.ts).
struct ComposerPromptSuggestionTests {
    static func run(_ id: String, _ ordinal: Int, _ status: String, started: Bool = true, completed: String? = nil) throws -> Run {
        var o: [String: Any] = ["id": id, "threadId": "t1", "ordinal": ordinal, "status": status, "requestedAt": "2026-01-01T00:00:00.000Z"]
        if started { o["startedAt"] = "2026-01-01T00:00:01.000Z" }
        if let completed { o["completedAt"] = completed }
        return try JSONDecoder().decode(Run.self, from: JSONSerialization.data(withJSONObject: o))
    }

    @Test func offeredWhileItsRunIsTheLatestCompletedRun() throws {
        let suggestion = ComposerPromptSuggestion.Suggestion(runId: RunId("r1"), text: "Run the tests")
        let done = try Self.run("r1", 1, "completed", completed: "2026-01-01T00:00:05.000Z")
        #expect(ComposerPromptSuggestion.offered(suggestion, latestRunId: RunId("r1"), runs: [done]) == suggestion)
        // A newer run takes over; a running one hides it.
        let running = try Self.run("r2", 2, "running")
        #expect(ComposerPromptSuggestion.offered(suggestion, latestRunId: RunId("r2"), runs: [done, running]) == nil)
        // #33706: a steered message leaves its queued run cancelled before it started; the suggestion stays.
        let steered = try Self.run("r2", 2, "cancelled", started: false, completed: "2026-01-01T00:00:06.000Z")
        #expect(ComposerPromptSuggestion.offered(suggestion, latestRunId: RunId("r2"), runs: [done, steered]) == suggestion)
        // The shell named a run the projection doesn't have yet.
        #expect(ComposerPromptSuggestion.offered(suggestion, latestRunId: RunId("r3"), runs: [done]) == nil)
        #expect(ComposerPromptSuggestion.decode(.null) == nil)
        #expect(ComposerPromptSuggestion.decode(.object(["runId": .string("r1"), "text": .string("Run the tests")])) == suggestion)
    }

    @Test func suggestionTakesOnlyTheDefaultPlaceholder() {
        #expect(ComposerLogic.placeholder(.init(), suggestion: "Run the tests") == "Run the tests")
        #expect(ComposerLogic.placeholder(.init(questionChoiceOnly: true), suggestion: "Run the tests") == "Choose an option above")
    }
}
