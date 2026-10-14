import AppKit
import DesignSystem

/// A section header's buttons in a row, `gap-1`, skipping hidden ones.
final class HeaderButtonsView: DSView {
    var buttons: [NSView] = [] { didSet { oldValue.forEach { $0.removeFromSuperview() }; buttons.forEach(addSubview); invalidateIntrinsicContentSize() } }
    private var shown: [NSView] { buttons.filter { !$0.isHidden } }

    override var intrinsicContentSize: NSSize {
        let sizes = shown.map(\.intrinsicContentSize)
        return NSSize(width: sizes.map(\.width).reduce(0, +) + CGFloat(max(0, sizes.count - 1)) * 4, height: sizes.map(\.height).max() ?? 0)
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 0
        for b in shown {
            let s = b.intrinsicContentSize
            b.frame = NSRect(x: x, y: (bounds.height - s.height) / 2, width: s.width, height: s.height)
            x += s.width + 4
        }
    }
}
