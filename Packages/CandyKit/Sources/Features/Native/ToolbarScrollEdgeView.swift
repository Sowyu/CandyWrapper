import AppKit

/// Glass Native's soft scroll edge under the toolbar: the rows that scroll under it blur, fading out just below its
/// bottom edge (T3 Mobile's transparent glass header with `scrollEdgeEffects: soft`, HomeScreen.tsx:245-247). One
/// within-window blur, redrawn by the window server only while what is behind it changes.
// ponytail: our own strip, because AppKit's scroll pocket needs the scroll view's content insets, which the timeline's
// scroll math doesn't use; switch to the system effect if the timeline moves to content insets
final class ToolbarScrollEdgeView: NSVisualEffectView {
    /// How far below the toolbar the blur fades out.
    static let fade: CGFloat = 14
    private let mask = CAGradientLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        blendingMode = .withinWindow
        material = .headerView
        state = .followsWindowActiveState
        wantsLayer = true
        mask.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        layer?.mask = mask
        setAccessibilityElement(false)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        mask.frame = bounds
        let solid = bounds.height > 0 ? max(0, (bounds.height - Self.fade) / bounds.height) : 0
        // The layer isn't flipped: location 0 is the bottom.
        let flipped = layer?.isGeometryFlipped == true || isFlipped
        mask.startPoint = CGPoint(x: 0.5, y: flipped ? 0 : 1)
        mask.endPoint = CGPoint(x: 0.5, y: flipped ? 1 : 0)
        mask.locations = [0, NSNumber(value: Double(solid)), 1]
        CATransaction.commit()
    }
}
