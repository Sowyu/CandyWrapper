import AppKit
import DesignSystem

/// RightPanelResizeHandle.tsx:18-39: eight-point hit area centered on the border, with a 1px line that
/// turns `border` on hover and `primary/60` while dragging (`transition-colors duration-150`, :30).
final class RightPanelResizeView: DSView {
    var onDrag: ((CGFloat) -> Void)?
    private var previousX: CGFloat = 0
    private let line = CALayer()
    private var hovered = false { didSet { if hovered != oldValue { redisplay(transitioning: [.background]) } } }
    private var pressed = false { didSet { if pressed != oldValue { redisplay(transitioning: [.background]) } } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        line.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(line)
    }

    @MainActor required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        line.frame = NSRect(x: (bounds.width / 2).rounded(.down), y: 0, width: 1, height: bounds.height)
    }

    override func updateLayer() {
        let color: NSColor? = pressed ? Themed.color(\.primary, 0.6) : hovered ? Themed.color(\.border) : nil
        Motion.setBackground(line, color?.cgColor(in: self))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func mouseDown(with event: NSEvent) { previousX = event.locationInWindow.x; pressed = true }
    override func mouseUp(with event: NSEvent) {
        pressed = false
        hovered = bounds.contains(convert(event.locationInWindow, from: nil))
    }
    override func mouseDragged(with event: NSEvent) {
        let x = event.locationInWindow.x
        onDrag?(previousX - x)
        previousX = x
    }
}

/// RightPanelSheet.tsx:23-29. The chat keeps its width under the modal surface.
final class RightPanelSheetBackdropView: DSView {
    var onClose: (() -> Void)?
    static func width(viewport: CGFloat, container: CGFloat) -> CGFloat {
        min(container, viewport <= 760 ? min(viewport * 0.88, 384) : max(320, min(viewport * 0.42, 448)))
    }
    override func mouseDown(with event: NSEvent) { onClose?() }
    override func cancelOperation(_ sender: Any?) { onClose?() }
    override func updateLayer() { layer?.backgroundColor = NSColor.black.withAlphaComponent(0.4).cgColor }
}
