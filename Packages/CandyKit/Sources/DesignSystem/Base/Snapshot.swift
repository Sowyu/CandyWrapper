import AppKit

/// Renders a view offscreen to a bitmap by rendering its layer tree. Used by the gallery
/// export and the visual tests, and works without a window or a GUI session.
@MainActor
public enum Snapshot {
    public static func image(of view: NSView, size: NSSize, scale: CGFloat = 2, dark: Bool) -> NSBitmapImageRep {
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        view.wantsLayer = true
        // AppKit links subview layers into the tree only inside a window. This one is never shown.
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.frame = NSRect(origin: .zero, size: size)
        layoutTree(view)
        window.display()
        CATransaction.flush()
        displayTree(view, scale: scale)
        defer { window.contentView = nil }
        if ProcessInfo.processInfo.environment["SNAPSHOT_DEBUG"] != nil {
            func count(_ l: CALayer) -> Int { 1 + (l.sublayers ?? []).reduce(0) { $0 + count($1) } }
            print("snapshot layers:", view.layer.map(count) ?? 0, "root sublayers:", view.layer?.sublayers?.count ?? 0)
        }
        let width = Int(size.width * scale), height = Int(size.height * scale)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!.retagging(with: .sRGB)!
        rep.size = size
        let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
        // The context already maps points to pixels (rep.size); flip y so the top-left origin lands at the top.
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        view.layer?.render(in: ctx)
        return rep
    }

    /// Runs layout top-down; outside a window nothing else triggers it.
    private static func layoutTree(_ view: NSView) {
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        view.subviews.forEach(layoutTree)
    }

    /// Redraws every layer in the tree at `scale` (the virtual screen here is 1x).
    private static func displayTree(_ view: NSView, scale: CGFloat) {
        view.displayIfNeeded()
        func redraw(_ layer: CALayer) {
            layer.contentsScale = scale
            if layer.delegate != nil || type(of: layer) != CALayer.self { layer.setNeedsDisplay() }
            layer.displayIfNeeded()
            layer.sublayers?.forEach(redraw)
        }
        if let root = view.layer { redraw(root) }
    }

    public static func writePNG(_ rep: NSBitmapImageRep, to url: URL) throws {
        try rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
