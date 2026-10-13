import AppKit

/// Glass Native's soft scroll edge under the toolbar: rows that scroll under the toolbar fade out, as content does
/// under a macOS 26 unified toolbar, with no band or tint at rest. An alpha mask on the scrolling view, so it works at
/// any Glass opacity: one gradient layer, redrawn only when the view's size or the toolbar's height changes.
// ponytail: our own mask, because AppKit's scroll pocket needs the scroll view's content insets, which the timeline's
// scroll math doesn't use; switch to the system effect if the timeline moves to content insets
@MainActor
final class ToolbarScrollFade {
    /// Rows are fully visible from this far below the toolbar's bottom edge.
    static let below: CGFloat = 16
    /// And fully gone this far above it.
    static let above: CGFloat = 12
    private let mask = CAGradientLayer()
    private weak var view: NSView?

    init(on view: NSView) {
        self.view = view
        view.wantsLayer = true
        mask.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor]
        mask.startPoint = CGPoint(x: 0.5, y: 0)
        mask.endPoint = CGPoint(x: 0.5, y: 1)
        mask.actions = ["bounds": NSNull(), "position": NSNull(), "locations": NSNull(), "startPoint": NSNull(), "endPoint": NSNull()]
        view.layer?.mask = mask
    }

    func remove() {
        if view?.layer?.mask === mask { view?.layer?.mask = nil }
    }

    /// `toolbar` is the toolbar's height over the view's top edge, `size` the view's size once laid out.
    func update(toolbar: CGFloat, size: CGSize) {
        guard let view, let layer = view.layer else { return }
        if layer.mask !== mask { layer.mask = mask }
        let h = max(1, size.height)
        mask.frame = CGRect(origin: .zero, size: size)
        let start = max(0, toolbar - Self.above) / h, end = min(h, toolbar + Self.below) / h
        // Location 0 is the top of a flipped layer and the bottom of an unflipped one.
        let flipped = layer.isGeometryFlipped || view.isFlipped
        mask.startPoint = CGPoint(x: 0.5, y: flipped ? 0 : 1)
        mask.endPoint = CGPoint(x: 0.5, y: flipped ? 1 : 0)
        mask.locations = [NSNumber(value: Double(start)), NSNumber(value: Double(end)), 1]
    }
}
