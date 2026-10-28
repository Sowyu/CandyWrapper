import AppKit
import Testing
@testable import Features

@MainActor
struct TerminalLifetimeTests {
    @Test func sharedGridClampsRenderingWithoutReportingItAsTheViewersSize() {
        let surface = TerminalSurfaceView(frame: NSRect(x: 0, y: 0, width: 900, height: 500))
        var reports: [(Int, Int)] = []
        surface.onResize = { reports.append(($0, $1)) }
        surface.layoutSubtreeIfNeeded()
        let local = surface.grid
        #expect(local.cols > 40 && local.rows > 10)
        reports.removeAll()
        surface.setSharedGrid(cols: 40, rows: 10)
        #expect(surface.grid.cols == 40 && surface.grid.rows == 10)
        surface.resendSize()
        #expect(reports.last?.0 == local.cols && reports.last?.1 == local.rows)
        surface.setSharedGrid(cols: nil, rows: nil)
        #expect(surface.grid.cols == local.cols && surface.grid.rows == local.rows)
    }

    @Test func closingPaneReleasesViewAndBuffer() {
        let group = TerminalSplitGroupView()
        weak var surface: TerminalSurfaceView?
        weak var terminal: NSView?
        weak var buffer: AnyObject?
        autoreleasepool {
            let pane = TerminalSurfaceView()
            surface = pane
            terminal = pane.terminal
            buffer = pane.terminal.getTerminal()
            group.show([(id: "term-1", surface: pane)], direction: .horizontal, activeId: "term-1")
            pane.apply(.write(String(repeating: "terminal output\r\n", count: 500)))
            group.show([], direction: .horizontal, activeId: "")
        }
        #expect(surface == nil)
        #expect(terminal == nil)
        #expect(buffer == nil)
    }
}
