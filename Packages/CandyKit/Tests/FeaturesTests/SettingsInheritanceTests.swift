import AppKit
import Testing
import DesignSystem
@testable import Features

@MainActor
struct SettingsInheritanceTests {
    @Test func localValuesRevealOnHoverAndKeyboardFocus() {
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous) }
        ThemeRuntime.apply(.init())
        let marker = InheritanceButton()
        for source in [SettingInheritanceState.default, .environment] {
            marker.state = source
            #expect(marker.button.alphaValue == 0)
            marker.mouseEntered(with: NSEvent())
            #expect(marker.button.alphaValue == 1)
            marker.mouseExited(with: NSEvent())
            #expect(marker.button.alphaValue == 0)
            var state = marker.button.state
            state.focusVisible = true
            marker.button.previewState(state)
            #expect(marker.button.alphaValue == 1)
            state.focusVisible = false
            marker.button.previewState(state)
            #expect(marker.button.alphaValue == 0)
        }
        marker.hasOverridingProjects = true
        #expect(marker.button.alphaValue == 1)
        marker.hasOverridingProjects = false
        for source in [SettingInheritanceState.inherited, .overridden, .mixed] {
            marker.state = source
            #expect(marker.button.alphaValue == 1)
        }
    }
}
