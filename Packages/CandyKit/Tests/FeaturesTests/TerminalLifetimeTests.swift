import AppKit
import Testing
@testable import Features

@MainActor
struct TerminalLifetimeTests {
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
