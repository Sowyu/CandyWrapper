import AppKit

/// A full-color mark drawn from an `NSImage` (a vector SVG or a bitmap) in place of a tinted `IconView`:
/// brand logos with gradients, masks or embedded images. Draws once per size or appearance change.
public final class ImageGlyphView: NSView {
    public var image: NSImage { didSet { needsDisplay = true } }

    public init(image: NSImage) {
        self.image = image
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    public override var isFlipped: Bool { true }
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }
    public override func draw(_ dirtyRect: NSRect) {
        image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}
