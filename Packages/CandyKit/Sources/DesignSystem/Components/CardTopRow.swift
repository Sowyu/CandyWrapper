import CoreGraphics

/// Redesign's top row for a card that shares its corner with the header pill: tabs from the left, the pill concentric in
/// the top right corner, and buttons such as maximize just left of the pill. The card's content starts at `height`.
/// The right panel uses it today; the thread's inset card layout can use the same row. Card coordinates, top-left origin.
public struct CardTopRow: Equatable, Sendable {
    /// The pill's inset from the card's top and right edges: concentric, so the pill's `control` corner runs parallel to
    /// the card's `card` corner.
    public static let pillInset = RedesignTokens.Radius.card - RedesignTokens.Radius.control
    /// A row as tall as the pill and its inset on both sides. A 24pt control centred in it sits 4pt in from the card's
    /// top, like the pill's own buttons do.
    public static let rowHeight = DitherTabStripView.tabHeight + 2 * pillInset
    /// The tabs' inset from the card's left edge, the same 4pt as from its top.
    public static let tabsInset = (rowHeight - 24) / 2
    /// The inset card's floating breadcrumb and header pill: this far in from the card's top, left and right edges.
    public static let floatGap = RedesignTokens.Space.s
    /// The band over the inset card's top that the floating pills take: the gap above and below a tab-high pill.
    public static let floatHeight = 2 * floatGap + DitherTabStripView.tabHeight
    /// The narrowest tab area still usable: one tab at its narrowest (60), the gap and the 24pt +. Below it the tabs
    /// drop to a second row under the pill.
    public static let minTabRoom: CGFloat = 60 + 4 + 24

    /// Where the pill goes. Zero size when there is no pill.
    public let pill: CGRect
    /// The trailing buttons, right to left from the pill, `Space.s` apart and from the pill.
    public let trailing: [CGRect]
    /// The tabs' area. Tabs never leave it, so they never reach the trailing buttons or the pill.
    public let tabs: CGRect
    /// The rows' total height: where the card's content starts.
    public let height: CGFloat

    /// Drops the tabs to their own row only when the pill and the trailing buttons leave them less than `minTabRoom`.
    public init(width: CGFloat, pill: CGSize, trailing: [CGSize] = []) {
        let gap = RedesignTokens.Space.s
        let mid = Self.rowHeight / 2
        self.pill = pill.width > 0
            ? CGRect(x: width - Self.pillInset - pill.width, y: Self.pillInset, width: pill.width, height: pill.height) : .zero
        var x = pill.width > 0 ? self.pill.minX - gap : width - Self.tabsInset
        var frames: [CGRect] = []
        for size in trailing {
            x -= size.width
            frames.append(CGRect(x: x, y: (mid - size.height / 2).rounded(), width: size.width, height: size.height))
            x -= gap
        }
        self.trailing = frames
        let room = x - Self.tabsInset
        if room >= Self.minTabRoom {
            tabs = CGRect(x: Self.tabsInset, y: 0, width: room, height: Self.rowHeight)
            height = Self.rowHeight
        } else {
            tabs = CGRect(x: Self.tabsInset, y: Self.rowHeight, width: max(0, width - 2 * Self.tabsInset), height: Self.rowHeight)
            height = 2 * Self.rowHeight
        }
    }
}
