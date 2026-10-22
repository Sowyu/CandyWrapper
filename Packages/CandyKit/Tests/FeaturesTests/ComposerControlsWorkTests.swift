import AppKit
import Testing
import T3Store
@testable import Features

@MainActor
struct ComposerControlsWorkTests {
    @Test func typingAndEqualContextUpdatesDoNotRebuildControls() throws {
        let pickers = try PickersFidelityTests.pickers()
        let model = try #require(pickers.modelButton.icon)
        let access = try #require(pickers.accessButton.icon)
        var replacements = 0
        for i in 0..<20 {
            pickers.prompt = "typing \(i)"
            pickers.update(context: pickers.context)
            if pickers.modelButton.icon !== model { replacements += 1 }
            if pickers.accessButton.icon !== access { replacements += 1 }
        }
        #expect(replacements == 0)
    }

    @Test func changedModelStillUpdatesControlsAndNotifies() throws {
        let pickers = try PickersFidelityTests.pickers()
        let before = pickers.modelButton.icon
        var notifications = 0
        pickers.onChange = { _ in notifications += 1 }
        let next = try #require(pickers.current.entry?.models.first { $0.slug != pickers.current.modelSlug })
        pickers.select("claudeAgent", model: next.slug)
        #expect(pickers.current.modelSlug == next.slug)
        #expect(pickers.modelButton.icon !== before)
        #expect(notifications == 1)
        let after = pickers.modelButton.icon
        pickers.select("claudeAgent", model: next.slug)
        #expect(pickers.modelButton.icon === after)
        #expect(notifications == 2)
    }
}
