import AppKit
import Testing
import DesignSystem
@testable import Features

/// A dialog over the terminal (Mod+W's "Close terminal?") blurs a snapshot of the window. SwiftTerm clears its cells
/// to transparent, so without the terminal painting its background the live terminal showed through sharp.
@MainActor
struct TerminalModalSnapshotTests {
    @Test func dialogSnapshotCoversTheTerminal() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        let content = DSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        window.contentView = content
        let surface = TerminalSurfaceView(frame: NSRect(x: 100, y: 0, width: 300, height: 200))
        content.addSubview(surface)
        surface.terminal.frame = surface.bounds
        surface.terminal.feed(text: "hello world\r\n")
        content.layoutSubtreeIfNeeded()
        let image = NSBitmapImageRep(cgImage: try #require(ModalHost.blurredSnapshot(of: content)))
        let center = try #require(image.colorAt(x: image.pixelsWide * 250 / 400, y: image.pixelsHigh / 2))
        #expect(center.alphaComponent == 1)
    }
}
