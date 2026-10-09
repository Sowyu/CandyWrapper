import AppKit

/// T3's `Separator` (`apps/web/src/components/ui/separator.tsx`): a 1px `--contrast-border` line.
/// The parent sets the length; horizontal is full width, vertical stretches to the row height.
public final class SeparatorView: DSView {
    public enum Orientation: String, Sendable { case horizontal, vertical }
    public var orientation: Orientation { didSet { invalidateIntrinsicContentSize() } }

    public init(_ orientation: Orientation = .horizontal) {
        self.orientation = orientation
        super.init(frame: .zero)
        setAccessibilityRole(.splitter)
    }

    public override var intrinsicContentSize: NSSize {
        orientation == .horizontal ? NSSize(width: NSView.noIntrinsicMetric, height: 1)
            : NSSize(width: 1, height: NSView.noIntrinsicMetric)
    }

    public override func updateLayer() {
        layer?.backgroundColor = Themed.color(\.contrastBorder).cgColor(in: self)
    }
}
