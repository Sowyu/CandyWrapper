import AppKit
import Testing
import DesignSystem
import T3Protocol
@testable import Features

/// Redesign's Context popover shows only what the provider reported: no estimated figure, no "~", and a plain line
/// before the first report.
@MainActor
struct ThreadContextPopoverModelTests {
    private func usage(_ fields: [String: JSONValue]) throws -> ThreadContextWindowUsage {
        var report = fields
        report["updatedAt"] = .string("2026-11-21T10:00:00.000Z")
        let projection = try JSONValue.object(["thread": .object(["id": .string("t")]), "updatedAt": .string("2026-11-21T10:00:01.000Z"),
                                               "providerTurns": .array([.object(["id": .string("pt"), "tokenUsage": .object(report)])])])
            .decode(as: ThreadProjection.self)
        return try #require(ThreadContextWindowUsage.derive(projection))
    }

    /// Every label and text block the popover shows.
    private func texts(_ usage: ThreadContextWindowUsage?) -> [String] {
        let view = ThreadContextWindowDetailsView()
        _ = view.configure(usage: usage, capy: true, model: "Opus 5.5", compactOffered: false, disabled: false, reason: nil)
        return view.subviews.filter { !$0.isHidden }.compactMap { ($0 as? LabelView)?.text ?? ($0 as? TextBlockView)?.text }
    }

    @Test func onlyReportedTotalsShowNoBreakdown() throws {
        let u = try usage(["usedTokens": .number(949_000), "maxTokens": .number(1_000_000)])
        #expect(u.breakdown == nil)
        #expect(ThreadContextWindowDetailsView.legend(u).isEmpty)
        let shown = texts(u)
        #expect(shown.contains("949K / 1M used (95%)"))
        #expect(!shown.contains { $0.contains("~") || $0.localizedCaseInsensitiveContains("estimat") })
        #expect(!shown.contains(ThreadContextWindowDetailsView.breakdownNote))
    }

    @Test func splitsOnlyWhenTheReportedPartsAddUpToTheTotal() throws {
        let exact = try usage(["usedTokens": .number(949_000), "maxTokens": .number(1_000_000), "inputTokens": .number(940_000),
                               "cachedInputTokens": .number(900_000), "outputTokens": .number(9_000)])
        let parts = try #require(exact.breakdown)
        #expect(parts.map(\.value) == [900_000, 40_000, 9_000])
        #expect(parts.map(\.value).reduce(0, +) == exact.used)
        let shown = texts(exact)
        #expect(shown.contains("900K") && shown.contains("40K") && shown.contains("9K"))
        #expect(!shown.contains { $0.contains("~") })

        // A report whose parts don't add up to usedTokens gets no split rather than a guessed one.
        let off = try usage(["usedTokens": .number(949_000), "inputTokens": .number(500_000), "outputTokens": .number(9_000)])
        #expect(off.breakdown == nil)
        let cachedOver = try usage(["usedTokens": .number(10), "inputTokens": .number(5), "cachedInputTokens": .number(6), "outputTokens": .number(5)])
        #expect(cachedOver.breakdown == nil)
    }

    @Test func aThreadSnapshotsCumulativeCountsAreNotUsedAsASplit() throws {
        let projection = try JSONValue.object([
            "thread": .object(["id": .string("t"), "activeProviderThreadId": .string("p")]), "updatedAt": .string("2026-11-21T10:00:01.000Z"),
            "providerThreads": .array([.object(["id": .string("p"), "contextUsage": .object([
                "usedTokens": .number(100), "inputTokens": .number(90), "outputTokens": .number(10)])])]),
        ]).decode(as: ThreadProjection.self)
        let u = try #require(ThreadContextWindowUsage.derive(projection))
        #expect(u.breakdown == nil)
    }

    @Test func saysPlainlyWhenNothingIsReported() {
        let shown = texts(nil)
        #expect(shown.contains(ThreadContextWindowDetailsView.unreportedNote))
        #expect(!shown.contains { $0.contains("0 /") || $0.contains("used") || $0.contains("%") })
    }
}
