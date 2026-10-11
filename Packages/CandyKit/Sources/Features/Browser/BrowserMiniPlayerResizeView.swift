import AppKit
import DesignSystem

/// Corner resize of the floating browser, previewMiniPlayerLayout.ts:325-392.
final class BrowserMiniPlayerResizeView: DSView {
    var onResize: ((CGSize) -> Void)?
    private var start = CGPoint.zero
    private var size = CGSize.zero
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func mouseDown(with event: NSEvent) { start = event.locationInWindow; size = superview?.bounds.size ?? .zero }
    override func mouseDragged(with event: NSEvent) {
        guard size.width > 0, size.height > 0, let parent = superview?.superview else { return }
        let dx = event.locationInWindow.x - start.x, dy = start.y - event.locationInWindow.y
        let aspect = size.width / size.height
        let desired = (size.width + dx + (size.height + dy) / aspect) / (1 + 1 / (aspect * aspect))
        let origin = superview?.frame.origin ?? .zero
        let width = min(max(desired, 240, 150 * aspect), max(1, parent.bounds.width - origin.x - 12), max(1, (parent.bounds.height - origin.y - 12) * aspect))
        onResize?(CGSize(width: width.rounded(), height: (width / aspect).rounded()))
    }
}
