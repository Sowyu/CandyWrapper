import Testing
@testable import Features

/// Redesign's context pill: status colors from the reported "Compact at", never the accent.
struct ContextRingLevelTests {
    @Test func levelFollowsCompactThreshold() {
        typealias U = ThreadContextWindowUsage
        // A threshold of 90%: warning from 80, danger from 90.
        #expect(U.level(percentage: 10, compactAt: 90) == .neutral)
        #expect(U.level(percentage: 79.9, compactAt: 90) == .neutral)
        #expect(U.level(percentage: 80, compactAt: 90) == .warning)
        #expect(U.level(percentage: 90, compactAt: 90) == .danger)
        // No threshold: warning from 80, danger from 95.
        #expect(U.level(percentage: 50, compactAt: nil) == .neutral)
        #expect(U.level(percentage: 80, compactAt: nil) == .warning)
        #expect(U.level(percentage: 94.9, compactAt: nil) == .warning)
        #expect(U.level(percentage: 95, compactAt: nil) == .danger)
        #expect(U.level(percentage: 100, compactAt: nil) == .danger)
        // A threshold above 95% still turns danger at 95.
        #expect(U.level(percentage: 96, compactAt: 98) == .danger)
    }

    @Test func usageReadsThresholdInTokens() {
        var u = ThreadContextWindowUsage(used: 949_000, maximum: 1_000_000, automatically: true)
        #expect(u.level == .danger)
        #expect(u.redesignSummary == "Context: 949K of 1M used (95%)")
        u.used = 700_000
        u.autoCompactThreshold = 800_000
        #expect(u.compactAtPercentage == 80)
        #expect(u.level == .warning)
        u.autoCompactThreshold = 9e16
        #expect(u.compactAtPercentage == nil && u.level == .neutral)
        u.maximum = nil
        #expect(u.redesignSummary == "Context: 700K used")
    }
}
