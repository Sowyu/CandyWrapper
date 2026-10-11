import AppKit
import DesignSystem

/// RightPanelResizeHandle.tsx:18-39: eight-point hit area centered on the border.
final class RightPanelResizeView: DSView {
    var onDrag: ((CGFloat) -> Void)?
    private var previousX: CGFloat = 0
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func mouseDown(with event: NSEvent) { previousX = event.locationInWindow.x }
    override func mouseDragged(with event: NSEvent) {
        let x = event.locationInWindow.x
        onDrag?(previousX - x)
        previousX = x
    }
}
