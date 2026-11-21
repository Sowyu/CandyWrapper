import AppKit
import Testing
import DesignSystem
@testable import Features

/// Redesign centres the palette on the composer's column (the column the thread page publishes through
/// `DitherArtView.setColumn`), not on the window, and falls back to the window when the content area is too narrow.
/// The default themes keep T3's window-centred popup.
@MainActor
struct PaletteCentreTests {
    private func withTheme(dither: Bool, _ body: () async throws -> Void) async rethrows {
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous) }
        var input = previous
        input.ditherLight = dither; input.ditherDark = dither
        ThemeRuntime.apply(input)
        try await body()
    }

    /// A window with a sidebar `sidebar` wide and a thread page beside it whose composer column is 736 wide (or the
    /// page less 96) centred in the page, as `ThreadPanelView.layoutComposer` publishes it.
    private func setUp(width: CGFloat, sidebar: CGFloat) -> (NSWindow, NSView, CommandPaletteOverlay) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        let container = DSView(frame: NSRect(x: 0, y: 0, width: width, height: 700))
        window.contentView = container
        let page = DSView(frame: NSRect(x: sidebar, y: 0, width: width - sidebar, height: 700))
        container.addSubview(page)
        publish(page)
        let overlay = CommandPaletteOverlay(controller: CommandPaletteController(source: .init(rootGroups: { [] })))
        overlay.present(in: window)
        overlay.layoutSubtreeIfNeeded()
        return (window, page, overlay)
    }

    private func publish(_ page: NSView) {
        let lane = min(736, page.bounds.width - 96)
        DitherArtView.setColumn(NSRect(x: ((page.bounds.width - lane) / 2).rounded(), y: 0, width: lane, height: 700), from: page)
    }

    private func paletteMidX(_ overlay: CommandPaletteOverlay) -> CGFloat {
        overlay.convert(overlay.controller.view.frame, to: nil).midX
    }

    @Test func centresOnTheComposerColumn() async {
        await withTheme(dither: true) {
            // Sidebar open: the column's centre, 130pt right of the window's.
            let (_, page, overlay) = setUp(width: 1200, sidebar: 260)
            #expect(paletteMidX(overlay) == 730) // 260 + 940 / 2
            // Sidebar collapses under the open palette: it follows to the window centre.
            page.frame = NSRect(x: 0, y: 0, width: 1200, height: 700)
            publish(page)
            overlay.layoutSubtreeIfNeeded()
            #expect(paletteMidX(overlay) == 600)
            overlay.close()
        }
    }

    @Test func narrowContentAreaFallsBackToTheWindowCentre() async {
        await withTheme(dither: true) {
            // A 440pt content area can't hold the 576pt palette and its 16pt margins.
            let (_, _, overlay) = setUp(width: 700, sidebar: 260)
            #expect(paletteMidX(overlay) == 350)
            overlay.close()
        }
    }

    @Test func clampsInsideTheContentArea() {
        // A column hard against the right edge: the palette stops 16pt inside the area.
        let x = CommandPaletteOverlay.panelX(width: 576, in: NSRect(x: 0, y: 0, width: 1000, height: 700),
                                             column: (NSRect(x: 800, y: 0, width: 200, height: 700), NSRect(x: 260, y: 0, width: 740, height: 700)))
        #expect(x == 408) // 1000 - 16 - 576
    }

    @Test func defaultThemesStayWindowCentred() async {
        await withTheme(dither: false) {
            let (_, _, overlay) = setUp(width: 1200, sidebar: 260)
            #expect(paletteMidX(overlay) == 600)
            overlay.close()
        }
    }
}
