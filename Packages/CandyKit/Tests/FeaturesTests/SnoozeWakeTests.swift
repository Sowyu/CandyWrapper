import Testing
import T3Protocol
import T3Store
@testable import Features

/// The open thread's wake timer (ChatView.tsx:4754-4779, T3 07cb902866): one shot at the snooze end plus 50 ms.
@MainActor
struct SnoozeWakeTests {
    @Test func delayRunsToTheWakeTime() throws {
        let snoozed = ComposerFeedbackTests.shell(#""status":"idle","latestRunId":null,"snoozedAt":"2026-06-20T00:00:00.000Z","snoozedUntil":"2026-06-20T01:00:00.000Z""#)
        let wake = try #require(snoozed.snoozedUntil?.epochMs)
        #expect(ThreadLineageController.wakeDelay(SidebarThread(snoozed), nowMs: wake - 1_000) == 1_050)
        #expect(ThreadLineageController.wakeDelay(SidebarThread(snoozed), nowMs: wake) == nil)
        // A far wake is capped like setTimeout's 32-bit delay.
        #expect(ThreadLineageController.wakeDelay(SidebarThread(snoozed), nowMs: wake - 3_000_000_000) == 2_147_483_647)
        #expect(ThreadLineageController.wakeDelay(SidebarThread(ComposerFeedbackTests.shell(#""status":"idle","latestRunId":null,"snoozedUntil":null"#)), nowMs: 0) == nil)
        #expect(ThreadLineageController.wakeDelay(nil, nowMs: 0) == nil)
    }
}
