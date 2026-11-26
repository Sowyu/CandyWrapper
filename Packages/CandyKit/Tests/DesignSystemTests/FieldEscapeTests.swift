import AppKit
import Testing
@testable import DesignSystem

@MainActor
struct FieldEscapeTests {
    /// 5258 1.3: Esc in a search field clears it first; a plain input leaves Esc to the dialog around it.
    @Test func escapeClearsOnlySearchFieldsWithText() {
        let search = InputView(placeholder: "Search", text: "abc")
        var changed: String?
        search.onChange = { changed = $0 }
        #expect(!search.clearOnEscape())
        search.escapeClears = true
        #expect(search.clearOnEscape())
        #expect(search.text.isEmpty && changed == "")
        #expect(!search.clearOnEscape())
    }
}
