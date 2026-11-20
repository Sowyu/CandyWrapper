import Testing
import T3Protocol
@testable import Features

/// #31418 (threadCommands.test.ts and threadTitleRegenerationToast.ts at 4928).
struct TitleRegenerationOutcomeTests {
    @Test func toastsFollowT3() {
        #expect(TitleRegenerationOutcome.toast([.reported(status: "renamed", message: nil)]) == nil)
        #expect(TitleRegenerationOutcome.toast([.unreported]) == nil)
        let kept = TitleRegenerationOutcome.toast([.reported(status: "unchanged", message: nil)])
        #expect(kept?.title == "Title kept")
        #expect(kept?.message == "The current title already fits this thread.")
        let failed = TitleRegenerationOutcome.toast([.reported(status: "failed", message: nil)])
        #expect(failed?.kind == .error)
        #expect(failed?.title == "Failed to regenerate thread title")
        #expect(failed?.message == "Title generation failed.")
        let mixed = TitleRegenerationOutcome.toast([.reported(status: "renamed", message: nil), .failure("offline"),
                                                    .reported(status: "failed", message: "No model")])
        #expect(mixed?.title == "Failed to regenerate 2 of 3 thread titles")
        #expect(mixed?.message == "offline")
        #expect(TitleRegenerationOutcome.toast([.reported(status: "unchanged", message: nil), .reported(status: "unchanged", message: nil)])?.title == "Titles kept")
        let some = TitleRegenerationOutcome.toast([.reported(status: "unchanged", message: nil), .reported(status: "renamed", message: nil)])
        #expect(some?.title == "Kept 1 of 2 titles")
        #expect(some?.message == "Those titles already fit their threads.")
    }
}
