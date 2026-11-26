import AppKit
import Testing
@testable import DesignSystem
@testable import Features

@MainActor
struct ThemeHexFieldTests {
    /// #29550: deleting through a hex keeps the typed text, and a shorthand hex commits only on blur.
    @Test func shorthandHexCommitsOnBlur() {
        let field = ThemeColorFieldView(role: .canvas, label: "Canvas")
        var committed: [String] = []
        field.onChange = { _, value in committed.append(value) }
        field.value = "#aabbcc"
        field.input.state.focused = true
        field.input.text = "#aabbc"
        field.input.text = "#aab"
        #expect(committed == ["#aabbc"])
        #expect(!field.input.isInvalid)
        field.value = "#123456"
        #expect(field.input.text == "#aab")
        field.input.state.focused = false
        #expect(committed == ["#aabbc", "#aab"])
    }
}
