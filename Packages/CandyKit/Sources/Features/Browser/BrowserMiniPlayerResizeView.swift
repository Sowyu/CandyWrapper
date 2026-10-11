import AppKit
import DesignSystem

/// previewMiniPlayerLayout.ts:325-392. Corners project motion onto the aspect diagonal.
@MainActor
enum BrowserMiniPlayerResizeDirection: CaseIterable {
    case north, south, east, west, northEast, northWest, southEast, southWest
    var west: Bool { self == .west || self == .northWest || self == .southWest }
    var east: Bool { self == .east || self == .northEast || self == .southEast }
    var north: Bool { self == .north || self == .northEast || self == .northWest }
    var south: Bool { self == .south || self == .southEast || self == .southWest }
    func resized(_ start: CGRect, delta: CGPoint, container: CGSize) -> CGRect {
        guard start.width > 0, start.height > 0 else { return start }
        let aspect = start.width / start.height
        let maxWidth = west ? start.maxX - 12 : east ? container.width - 12 - start.minX : container.width - 24
        let maxHeight = north ? start.maxY - 12 : south ? container.height - 12 - start.minY : container.height - 24
        let desiredWidth = start.width + (east ? delta.x : west ? -delta.x : 0)
        let desiredHeight = start.height + (south ? delta.y : north ? -delta.y : 0)
        let desired = (west || east) && (north || south)
            ? (desiredWidth + desiredHeight / aspect) / (1 + 1 / (aspect * aspect))
            : (west || east) ? desiredWidth : desiredHeight * aspect
        let width = min(max(desired, 240, 150 * aspect), max(1, maxWidth), max(1, maxHeight * aspect)).rounded()
        let size = CGSize(width: width, height: (width / aspect).rounded())
        let origin = CGPoint(x: west ? start.maxX - size.width : start.minX, y: north ? start.maxY - size.height : start.minY)
        return BrowserMiniPlayerView.frame(size: size, origin: origin, container: CGRect(origin: .zero, size: container))
    }
}

final class BrowserMiniPlayerResizeView: DSView {
    let direction: BrowserMiniPlayerResizeDirection
    var onResize: ((CGRect) -> Void)?
    private var start = CGPoint.zero
    private var startFrame = CGRect.zero
    init(direction: BrowserMiniPlayerResizeDirection) { self.direction = direction; super.init(frame: .zero) }
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: direction == .east || direction == .west ? .resizeLeftRight : direction == .north || direction == .south ? .resizeUpDown : .crosshair)
    }
    override func mouseDown(with event: NSEvent) { start = event.locationInWindow; startFrame = superview?.frame ?? .zero }
    override func mouseDragged(with event: NSEvent) {
        guard let parent = superview?.superview else { return }
        onResize?(direction.resized(startFrame, delta: CGPoint(x: event.locationInWindow.x - start.x, y: start.y - event.locationInWindow.y), container: parent.bounds.size))
    }
}
