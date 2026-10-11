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
