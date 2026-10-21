import AppKit
import Testing
import DesignSystem
@testable import Features

/// Dither shows T3's first compact-before-send control, a "Compact and send" button with a send-options menu, in
/// place of the round send button and the Compact chip.
@MainActor
struct DitherCompactSendTests {
    @Test func ditherSplitsCompactAndSend() throws {
        var input = ThemeRuntimeInput()
        input.ditherDark = true
        input.ditherLight = true
        ThemeRuntime.apply(input)
        defer { ThemeRuntime.apply(ThemeRuntimeInput()) }
        let composer = ComposerView(frame: NSRect(x: 0, y: 0, width: 640, height: 150))
        composer.text = "hello"
        composer.compactBeforeSendTokens = 128_000
        composer.layoutSubtreeIfNeeded()
        let pills = composer.subviews.compactMap { $0 as? MessageActionPill }.filter { !$0.isHidden }
        #expect(pills.contains { $0.title == "Compact and send" })
        #expect(composer.compactPill.isHidden)
        let rep = Snapshot.image(of: composer, size: composer.bounds.size, scale: 2, dark: true)
        try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/dither-compact-send.png"))
    }
}
