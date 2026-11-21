import AppKit
import Testing
@testable import DesignSystem
@testable import Features

/// Inline HTML renders and MCP apps clip to Redesign's surface corner; T3's themes keep its square frame.
@MainActor
struct HtmlFrameCornerTests {
    @Test func inlineFrameRoundsOnlyUnderRedesign() {
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous) }
        var redesign = ThemeRuntimeInput(
            light: ThemeRuntimeHalf(colors: ThemeDefinition.dither.colors(for: .light)!),
            dark: ThemeRuntimeHalf(colors: ThemeDefinition.dither.colors(for: .dark)!))
        redesign.ditherLight = true; redesign.ditherDark = true
        for (input, radius) in [(redesign, RedesignTokens.Radius.card), (ThemeRuntimeInput(), 0)] {
            ThemeRuntime.apply(input)
            let frame = ThreadWebFrameView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
            frame.appearance = NSAppearance(named: .darkAqua)
            frame.roundsInRedesign = true
            frame.layout()
            #expect(frame.layer?.cornerRadius == radius)
            #expect(frame.layer?.masksToBounds == (radius > 0))
            // The expanded dialog and full screen keep their own chrome.
            frame.roundsInRedesign = false
            #expect(frame.layer?.cornerRadius == 0 && frame.layer?.masksToBounds == false)
        }
    }

    /// Opt-in picture for review: CANDY_RING_RENDER_DIR. A solid view stands in for the web content, which an
    /// offscreen capture cannot draw.
    @Test func renderCorner() throws {
        guard let dir = ProcessInfo.processInfo.environment["CANDY_RING_RENDER_DIR"] else { return }
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous) }
        var input = ThemeRuntimeInput(
            light: ThemeRuntimeHalf(colors: ThemeDefinition.dither.colors(for: .light)!),
            dark: ThemeRuntimeHalf(colors: ThemeDefinition.dither.colors(for: .dark)!))
        input.ditherLight = true; input.ditherDark = true
        ThemeRuntime.apply(input)
        for rounds in [false, true] {
            let root = DSView(frame: NSRect(x: 0, y: 0, width: 360, height: 180))
            root.wantsLayer = true
            root.appearance = NSAppearance(named: .darkAqua)
            root.layer?.backgroundColor = NSColor(srgbRed: 0.2, green: 0.2, blue: 0.22, alpha: 1).cgColor
            let frame = ThreadWebFrameView(frame: NSRect(x: 20, y: 20, width: 320, height: 140))
            let content = NSView(frame: frame.bounds)
            content.wantsLayer = true
            content.layer?.backgroundColor = NSColor.black.cgColor
            content.autoresizingMask = [.width, .height]
            frame.addSubview(content)
            root.addSubview(frame)
            frame.roundsInRedesign = rounds
            frame.layout()
            let rep = Snapshot.image(of: root, size: root.frame.size, scale: 2, dark: true)
            try rep.representation(using: .png, properties: [:])!
                .write(to: URL(fileURLWithPath: dir).appendingPathComponent("html-frame-\(rounds ? "after" : "before").png"))
        }
    }
}
