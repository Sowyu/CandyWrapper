import AppKit
import DesignSystem

/// RightPanelResizeHandle.tsx:18-39: eight-point hit area centered on the border, with a 1px line that
/// turns `border` on hover and `primary/60` while dragging (`transition-colors duration-150`, :30).
final class RightPanelResizeView: DSView {
    /// How far the pointer moved since the last call: left for the panel's handle, up for a `vertical` one.
    var onDrag: ((CGFloat) -> Void)?
    /// A drag that moved ended.
    var onDragEnd: (() -> Void)?
    private var previousX: CGFloat = 0
    private var dragged = false
    /// Redesign's terminal drawer handle: it fills the gap above the drawer card, with a row-resize cursor and a
    /// horizontal line.
    var vertical = false { didSet { if vertical != oldValue { needsLayout = true; window?.invalidateCursorRects(for: self) } } }
    /// Redesign's handle fills the gap beside the card, so its line sits in the gap's middle.
    var centersLine = false { didSet { if centersLine != oldValue { needsLayout = true } } }
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
        // The hover line sits on the handle's left edge (`left-0 -translate-x-1/2`), where the panel border is.
        line.frame = vertical ? NSRect(x: 0, y: ((bounds.height - 1) / 2).rounded(), width: bounds.width, height: 1)
            : NSRect(x: centersLine ? ((bounds.width - 1) / 2).rounded() : 0, y: 0, width: 1, height: bounds.height)
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
    override var mouseDownCanMoveWindow: Bool { vertical ? false : super.mouseDownCanMoveWindow }
    override func resetCursorRects() { addCursorRect(bounds, cursor: vertical ? .resizeUpDown : .resizeLeftRight) }
    override func mouseDown(with event: NSEvent) {
        previousX = vertical ? event.locationInWindow.y : event.locationInWindow.x
        pressed = true
        dragged = false
    }
    override func mouseUp(with event: NSEvent) {
        pressed = false
        hovered = bounds.contains(convert(event.locationInWindow, from: nil))
        if dragged { dragged = false; onDragEnd?() }
    }
    override func mouseDragged(with event: NSEvent) {
        // Window coordinates run up: a vertical handle reports upward travel, the panel's leftward.
        let x = vertical ? event.locationInWindow.y : event.locationInWindow.x
        onDrag?(vertical ? x - previousX : previousX - x)
        previousX = x
        dragged = true
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
