import AppKit
import Testing
import DesignSystem
@testable import Features

/// T3's palette backdrop is a live `backdrop-filter`: toggling the sidebar under the open palette shows the new layout.
/// The overlay takes a fresh snapshot when the views under it move, leaving itself out of it.
@MainActor
struct PaletteBackdropTests {
    final class Fill: DSView {
        let color: NSColor
        init(_ color: NSColor, frame: NSRect) { self.color = color; super.init(frame: frame) }
        @MainActor required init?(coder: NSCoder) { fatalError() }
        override func updateLayer() { layer?.backgroundColor = color.cgColor }
    }

    static func pixel(_ image: CGImage?, x: CGFloat, of width: CGFloat) throws -> NSColor {
        let rep = NSBitmapImageRep(cgImage: try #require(image))
        return try #require(rep.colorAt(x: Int(x / width * CGFloat(rep.pixelsWide)), y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB))
    }

    @Test func backdropFollowsTheLayoutUnderTheOverlay() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        let container = DSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        window.contentView = container
        let sidebar = Fill(.systemRed, frame: NSRect(x: 0, y: 0, width: 100, height: 200))
        let main = Fill(.systemBlue, frame: NSRect(x: 100, y: 0, width: 300, height: 200))
        container.addSubview(sidebar)
        container.addSubview(main)
        let overlay = CommandPaletteOverlay(controller: CommandPaletteController(source: .init(rootGroups: { [] })))
        overlay.present(in: window)
        #expect(window.firstResponder === overlay.controller.view.input || window.firstResponder is NSTextView)
        // The overlay leaves itself out of a fresh snapshot.
        let fresh = ModalHost.blurredSnapshot(of: container, excluding: overlay)
        let c = try Self.pixel(fresh, x: 50, of: 400)
        #expect(c.redComponent > 0.8, "\(c)")
        #expect(overlay.layer?.isHidden == false)
        // The sidebar closes: the backdrop follows on the next turn.
        sidebar.frame.origin.x = -100
        main.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        try await Task.sleep(for: .milliseconds(50))
        #expect(try Self.pixel(overlay.backdrop, x: 50, of: 400).blueComponent > 0.8)
    }
}
