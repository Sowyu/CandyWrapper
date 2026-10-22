import AppKit
import Testing
import DesignSystem
@testable import Features

/// Redesign's account e-mail rests blurred; a click on it shows it and a second click blurs it again.
@MainActor
struct AccountEmailRevealTests {
    @Test func clickingTheEmailTogglesItAndTheRestOpensTheMenu() {
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous) }
        var dither = previous
        dither.ditherLight = true; dither.ditherDark = true
        ThemeRuntime.apply(dither)
        let row = SidebarAccountRowView(frame: NSRect(x: 0, y: 0, width: 240, height: 44))
        row.appearance = NSAppearance(named: .darkAqua)
        row.set(name: "A", detail: "a@example.com", image: nil, initials: nil)
        #expect(!row.redacted.isHidden && row.detail.alphaValue == 0)
        row.pressOnEmail = true
        row.performAction()
        #expect(row.revealed && row.detail.alphaValue == 1)
        row.performAction()
        #expect(!row.revealed && row.detail.alphaValue == 0)
        // A new account starts blurred.
        row.performAction()
        row.set(name: "B", detail: "b@example.com", image: nil, initials: nil)
        #expect(!row.revealed && row.detail.alphaValue == 0)
    }
}
