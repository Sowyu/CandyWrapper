import Testing
@testable import T3Store

/// Launch withdraws only what Space scheduled: its "space." reminder ids, never a thread's notification.
struct SpaceReminderLeftoversTests {
    @Test func picksOnlySpaceReminders() {
        let ids = ["space.4f1c.due.2026-10-27", "space.9a.remind.2026-11-01T09:00", "env-1:thread-7", "local:space.thread", "spacecraft"]
        #expect(SpaceReminderLeftovers.ids(ids) == ["space.4f1c.due.2026-10-27", "space.9a.remind.2026-11-01T09:00"])
        #expect(SpaceReminderLeftovers.ids([]).isEmpty)
    }
}
