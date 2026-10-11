import AppKit
import DesignSystem

/// `QuitHoldOverlay` (apps/web/src/components/QuitHoldOverlay.tsx): a pill 22% down the window,
/// centered, `rounded-full bg-foreground/95 px-8 py-4 text-2xl font-bold text-background shadow-xl`.
/// It never takes clicks. `show(_:)` and `hide(linger:)` follow the hint events.
public final class QuitHoldOverlayView: DSView {
    private let decoration = BoxDecorationLayer()
    private let label = LabelView()
    private var hideTimer: Timer?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.masksToBounds = false
        decoration.host = self
        decoration.outset = 48
        layer?.addSublayer(decoration)
        label.font = DSFont.ui(24, weight: .bold)
        label.lineHeight = 32
        label.truncates = false
        addSubview(label)
        isHidden = true
        setAccessibilityRole(.staticText)
        restyle()
    }

    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    public var text: String { label.text }

    /// Sizes and places the pill in `container` (the window's content bounds, flipped or not).
    public func place(in container: NSRect, flipped: Bool) {
        let w = ceil(label.intrinsicContentSize.width) + 64, h: CGFloat = 64
        let top = (container.height * 0.22).rounded(.down)
        let y = flipped ? top : container.height - top - h
        frame = NSRect(x: ((container.width - w) / 2).rounded(), y: y, width: w, height: h)
    }

    public func show(_ mode: QuitHoldController.Mode) {
        hideTimer?.invalidate()
        hideTimer = nil
        label.text = QuitHoldController.overlayMessage(mode)
        if let superview { place(in: superview.bounds, flipped: superview.isFlipped) }
        needsLayout = true
        isHidden = false
    }

    /// A released hold hint lingers 1.2 s; a double-press hint goes at once (QuitHoldOverlay.tsx:5-33).
    public func hide(after mode: QuitHoldController.Mode?) {
        hideTimer?.invalidate()
        guard mode == .hold else {
            isHidden = true
            return
        }
        hideTimer = Timer.scheduledTimer(withTimeInterval: QuitHoldController.holdHintLinger, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isHidden = true
                self?.hideTimer = nil
            }
        }
        hideTimer?.tolerance = QuitHoldController.holdHintLinger / 10
        hideTimer?.tolerance = 0.06
    }

    public override func layout() {
        super.layout()
        decoration.layout(boxSize: bounds.size)
        label.frame = NSRect(x: 32, y: 16, width: bounds.width - 64, height: 32)
    }

    public override func updateLayer() { restyle() }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
        decoration.setNeedsDisplay()
    }

    private func restyle() {
        var box = BoxStyle()
        box.radius = 32
        box.fill = Themed.color(\.foreground, 0.95)
        // shadow-xl
        box.shadows = [BoxShadow(y: 20, blur: 25, spread: -5, color: Themed.black(0.1)),
                       BoxShadow(y: 8, blur: 10, spread: -6, color: Themed.black(0.1))]
        decoration.boxStyle = box
        label.color = Themed.color(\.background)
    }
}
