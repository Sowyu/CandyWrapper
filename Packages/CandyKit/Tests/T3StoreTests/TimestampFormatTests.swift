import Testing
@testable import T3Store

/// Ports of apps/web/src/timestampFormat.test.ts for the relative-time functions. The JS tests fake
/// the clock at 2026-04-07T12:00:00Z; these pass that instant as `nowMs`.
@Suite struct TimestampFormatPortTests {
    private let now = ms("2026-04-07T12:00:00.000Z")
    private typealias F = TimestampFormat

    @Test func relativeTimeUntilLabel() {
        #expect(F.formatRelativeTimeUntilLabel("2026-04-07T11:59:00.000Z", nowMs: now) == "Expired")
        #expect(F.formatRelativeTimeUntilLabel("2026-04-07T12:00:45.000Z", nowMs: now) == "45s left")
        #expect(F.formatRelativeTimeUntilLabel("2026-04-07T12:15:00.000Z", nowMs: now) == "15m left")
        #expect(F.formatRelativeTimeUntilLabel("2026-04-07T18:00:00.000Z", nowMs: now) == "6h left")
    }

    @Test func expiresInLabel() {
        #expect(F.formatExpiresInLabel("2026-04-07T11:59:00.000Z", nowMs: now) == "Expired")
        #expect(F.formatExpiresInLabel("2026-04-07T12:00:45.000Z", nowMs: now) == "Expires in 45s")
        #expect(F.formatExpiresInLabel("2026-04-07T12:04:12.000Z", nowMs: now) == "Expires in 4m 12s")
        #expect(F.formatExpiresInLabel("2026-04-07T12:15:00.000Z", nowMs: now) == "Expires in 15m")
        #expect(F.formatExpiresInLabel("2026-04-07T14:02:03.000Z", nowMs: now) == "Expires in 2h 2m 3s")
        #expect(F.formatExpiresInLabel("2026-04-07T18:00:00.000Z", nowMs: now) == "Expires in 6h")
    }

    @Test func invalidInputsGiveEmptyLabels() {
        #expect(F.formatRelativeTime("not-a-date", nowMs: now) == nil)
        #expect(F.formatRelativeTimeLabel("not-a-date", nowMs: now) == "")
        #expect(F.getRelativeTimeState(nil, nowMs: now) == .missing)
        #expect(F.getRelativeTimeState("not-a-date", nowMs: now) == .invalid)
        #expect(F.formatElapsedDurationLabel("not-a-date", nowMs: now) == "")
        #expect(F.formatRelativeTimeUntil("not-a-date", nowMs: now) == nil)
        #expect(F.formatRelativeTimeUntilLabel("not-a-date", nowMs: now) == "")
        #expect(F.formatExpiresInLabel("not-a-date", nowMs: now) == "")
    }

    @Test func relativeTimeState() {
        #expect(F.getRelativeTimeState("2026-04-07T11:45:00.000Z", nowMs: now) == .relative(value: "15m", suffix: "ago"))
    }

    @Test func elapsedDurationLabel() {
        #expect(F.formatElapsedDurationLabel("2026-04-07T12:00:00.000Z", nowMs: now) == "just now")
        #expect(F.formatElapsedDurationLabel("2026-04-07T12:01:00.000Z", nowMs: now) == "just now")
        #expect(F.formatElapsedDurationLabel("2026-04-07T11:59:45.000Z", nowMs: now) == "15s")
        #expect(F.formatElapsedDurationLabel("2026-04-07T11:45:00.000Z", nowMs: now) == "15m")
        #expect(F.formatElapsedDurationLabel("2026-04-07T06:00:00.000Z", nowMs: now) == "6h")
        #expect(F.formatElapsedDurationLabel("2026-04-03T12:00:00.000Z", nowMs: now) == "4d")
    }

    /// Not in T3's test file; checks the sidebar's "14m", "2h" form end to end.
    @Test func relativeLabelsAndSidebarCompaction() {
        let label = { (iso: String) in F.compactSidebarTimeLabel(F.formatRelativeTimeLabel(iso, nowMs: now)) }
        #expect(label("2026-04-07T12:00:30.000Z") == "now")
        #expect(label("2026-04-07T11:59:01.000Z") == "now")
        #expect(label("2026-04-07T11:46:00.000Z") == "14m")
        #expect(label("2026-04-07T10:00:00.000Z") == "2h")
        #expect(label("2026-04-05T11:00:00.000Z") == "2d")
        #expect(F.formatRelativeTimeLabel("2026-04-07T10:00:00.000Z", nowMs: now) == "2h ago")
    }
}
