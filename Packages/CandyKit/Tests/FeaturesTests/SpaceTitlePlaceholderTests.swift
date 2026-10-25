import AppKit
import Testing
@testable import Features

/// A new page's "Untitled" sits on the line the typed title takes, under the breadcrumb, also while the title is being
/// edited. AppKit's own placeholder drew half a line high over the breadcrumb on the user's Mac in 1.14.0.
@MainActor
struct SpaceTitlePlaceholderTests {
    /// Bounds of drawn pixels in the title band, in points from the header's top left.
    func bounds(text: String, focus: Bool, scale: CGFloat) -> String {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 300))
        window.contentView = root
        let header = SpacePageHeaderView(frame: NSRect(x: 40, y: 0, width: 720, height: 186))
        root.addSubview(header)
        header.update(crumb: ["Space", "Notes HQ"], title: text, meta: (edited: "today at 20:05", counts: nil), view: .page)
        header.layoutSubtreeIfNeeded()
        let title = header.subviews.compactMap { $0 as? NSTextField }.first { $0.isEditable }!
        if focus { window.makeFirstResponder(title) }
        header.layoutSubtreeIfNeeded()
        let w = Int(720 * scale), h = Int(186 * scale)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = header.bounds.size
        header.cacheDisplay(in: header.bounds, to: rep)
        var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
        for y in Int(76 * scale)..<Int(128 * scale) {
            for x in 0..<Int(200 * scale) where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        return "x \(Double(minX) / scale)-\(Double(maxX) / scale) y \(Double(minY) / scale)-\(Double(maxY) / scale)"
    }

    @Test func placeholderCoversTheTypedTitle() {
        let typed = bounds(text: "Untitled", focus: false, scale: 2)
        #expect(bounds(text: "", focus: false, scale: 2) == typed)
        #expect(bounds(text: "", focus: true, scale: 2) == typed)
    }
}
