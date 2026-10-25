import AppKit
import DesignSystem
import Testing
import T3Store
@testable import Features

/// "Keep Conductor out" in Redesign's thread menu: one label with a check while it's on, and the line that says what it
/// does under it and as its tooltip.
@MainActor @Suite struct DitherThreadMenuKeepOutTests {
    @Test func keepOutReadsTheSameEitherWayAndSaysWhatItDoes() {
        let detail = "Conductor can read this thread but won't send it messages."
        for on in [false, true] {
            let built = DitherThreadMenu.items([ThreadMenuItem("archive", "Archive"),
                                                ThreadMenuItem("hands-off", "Keep Conductor out", checked: on, detail: detail)],
                                               presets: [], openInNewTab: false) { _ in }
            let row = built.items.first { $0.title == "Keep Conductor out" }
            if case .checkbox(let checked)? = row?.kind { #expect(checked == on) } else { Issue.record("not a checkbox row") }
            #expect(row?.subtitle == detail)
            #expect(row?.tooltip == detail)
            #expect(row?.widensForSubtitle == true)
        }
        // Other rows keep their plain look.
        let plain = DitherThreadMenu.items([ThreadMenuItem("archive", "Archive")], presets: [], openInNewTab: false) { _ in }
        #expect(plain.items.first?.subtitle == nil)
    }
}
