import AppKit

extension NSEvent {
    /// The vertical scroll in points, for views that scroll their own content. A trackpad or Magic Mouse reports points
    /// already; a clicky wheel reports lines (one per notch, more as it accelerates), so each line moves a row's worth.
    public var scrollPointsY: CGFloat {
        hasPreciseScrollingDeltas ? scrollingDeltaY : scrollingDeltaY * Self.wheelLine
    }

    // ponytail: one line is 24pt for every list; tune per list if a dense one feels fast
    static let wheelLine: CGFloat = 24
}
