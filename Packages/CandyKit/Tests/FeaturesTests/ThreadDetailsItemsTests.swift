import AppKit
import Testing
@testable import Features
import T3Protocol

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
        // Workspace keeps no rows here (no Open in or scripts), so neither section shows.
        #expect(card.preferredHeight(.full) == 2)
    }
}
