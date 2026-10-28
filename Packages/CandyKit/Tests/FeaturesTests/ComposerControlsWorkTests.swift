import AppKit
import Testing
import T3Store
import DesignSystem
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

    @Test func fontSettingsRefreshTheComposerControlWithoutDoubleScaling() throws {
        let previousTheme = ThemeRuntime.input, previousFonts = FontRuntime.input
        defer { ThemeRuntime.apply(previousTheme); FontRuntime.apply(previousFonts) }
        ThemeRuntime.apply(.init()); FontRuntime.apply(.init())
        let control = ComposerControlView(title: "Medium")
        let label = try #require(control.subviews.compactMap { $0 as? LabelView }.first)
        var input = FontRuntimeInput(); input.interfaceSize = 20
        FontRuntime.apply(input); control.fontRuntimeDidChange(); label.fontRuntimeDidChange()
        #expect(label.font.pointSize == 17.5)
        input.interfaceFamily = "Menlo"
        FontRuntime.apply(input); control.fontRuntimeDidChange(); label.fontRuntimeDidChange()
        #expect(label.font.familyName == "Menlo")
        #expect(label.font.pointSize == 17.5)
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
