import AppKit
import Testing
@testable import Features
import T3Protocol
import T3Store

/// The thread details items (4928 threadDetailsItems.ts, #26904).
@MainActor
struct ThreadDetailsItemsTests {
    @Test func storesOnlyChangesFromTheDefault() {
        var settings = ClientSettings.defaults
        var shown = ThreadDetailsItems.visibility(settings)
        #expect(ThreadDetailsItems.isDefault(shown))
        #expect(shown["usage"] == false && shown["lineage"] == true)
        let lineage = ThreadDetailsItems.all.first { $0.id == "lineage" }!
        settings.apply(["threadDetailsItems": ThreadDetailsItems.setting(settings, lineage, visible: false)])
        #expect(settings["threadDetailsItems"] == .object(["lineage": .bool(false)]))
        settings.apply(["threadDetailsItems": ThreadDetailsItems.setting(settings, lineage, visible: true)])
        #expect(settings["threadDetailsItems"] == .object([:]))
        // The retired Labs flag defaults Usage and Context on.
        settings.apply(["threadDetailsUsageEnabled": .bool(true)])
        shown = ThreadDetailsItems.visibility(settings)
        #expect(shown["usage"] == true && shown["context"] == true && !ThreadDetailsItems.isDefault(shown))
        settings.apply(ThreadDetailsItems.reset)
        #expect(ThreadDetailsItems.isDefault(ThreadDetailsItems.visibility(settings)))
    }

    @Test func hiddenItemsLeaveTheCard() {
        let card = ThreadDetailsCardView()
        card.showsOpenIn = true
        card.items = [:]
        let full = card.preferredHeight(.full)
        card.items = ["environment": false]
        #expect(card.preferredHeight(.full) == full - 32)
        // Without any Workspace row its padding and the rule above Version Control go too.
        card.items = ["environment": false, "openIn": false]
        #expect(card.preferredHeight(.full) == full - 64 - 18 - 1)
        card.items = ["environment": false, "openIn": false, "branch": false, "changes": false, "gitActions": false]
        // Nothing left: the card offers "Choose what to show" (ThreadDetailsPanel.tsx:289-305).
        #expect(abs(card.preferredHeight(.full) - (2 + 8 + 32 + 8)) < 0.01)
        // Usage and Context show at every density once chosen and filled.
        card.items = [:]
        card.context.rows = [ThreadDetailsUsageRow.context(ThreadContextWindowUsage(used: 50_000, maximum: 200_000, automatically: true))]
        let plain = ThreadDetailsCardView()
        plain.showsOpenIn = true
        #expect(card.preferredHeight(.compact) == plain.preferredHeight(.compact))
        card.items = ["context": true]
        #expect(card.preferredHeight(.essential) > 2 + 32)
    }

    /// `ThreadDetailsContext` and `LimitRow` (ThreadDetailsUsage.tsx:84-205).
    @Test func usageRowsReadLikeT3() {
        let context = ThreadDetailsUsageRow.context(ThreadContextWindowUsage(used: 172_000, maximum: 200_000, autoCompactThreshold: 180_000, automatically: true))
        #expect(context.value == "172k / 200k" && context.fill == 86 && context.tone == .warning && context.muted)
        #expect(context.tick == 90)
        #expect(context.tooltip == ["Context: 86% used", "172,000 of 200,000 tokens", "Compacts automatically at about 180,000 tokens."])
        let now: Int64 = 1_800_000_000_000
        let reset = T3Timestamp(epochMs: now + 3_600_000).raw
        let w = UsageLimitWindow(id: "5h", kind: "session", label: "5h", usedPercent: 85, resetsAt: reset, windowDurationMins: 300)
        let row = ThreadDetailsUsageRow.limit(w, nowMs: now)
        #expect(row.value == "15%" && row.tone == .warning && row.tick == 20 && row.opensUsage)
        #expect(row.tooltip.first == "5h: 15% left" && row.tooltip[1] == "On pace · 20% of the window left")
    }
}
