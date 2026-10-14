import AppKit

/// T3's `DiscoveryList` (`apps/web/src/components/ui/discovery-list.tsx`): a 14px-radius framed list of
/// button rows (icon, title, description), divided by border/60. Spec: ui-components-b.md section 22.
public final class DiscoveryListView: BoxView {
    public let rows: [DiscoveryRowView]
    private let dividers: [CALayer]

    public init(rows: [DiscoveryRowView]) {
        self.rows = rows
        dividers = rows.dropFirst().map { _ in CALayer() }
        super.init(frame: .zero)
        var box = BoxStyle()
        box.radius = 14
        box.border = Themed.color(\.contrastBorder, 0.7)
        box.fill = WindowGlass.paneFill
        boxStyle = box
        rows.forEach(addSubview)
        dividers.forEach { layer?.addSublayer($0) }
        // `overflow-hidden`: row hovers stay inside the rounded frame.
        layer?.cornerRadius = 14
        layer?.masksToBounds = true
    }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 2 + CGFloat(rows.count) * 60 + CGFloat(max(0, rows.count - 1)))
    }

    public override func layout() {
        super.layout()
        // masksToBounds also clips the decoration layer, which has no shadows here.
        decoration.layout(boxSize: bounds.size)
        var y: CGFloat = 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, row) in rows.enumerated() {
            if i > 0 {
                dividers[i - 1].frame = CGRect(x: 1, y: y, width: bounds.width - 2, height: 1)
                y += 1
            }
            row.frame = NSRect(x: 1, y: y, width: bounds.width - 2, height: 60)
            y += 60
        }
        CATransaction.commit()
    }

    public override func updateLayer() {
        let color = Themed.color(\.contrastBorder, 0.6).cgColor(in: self)
        dividers.forEach { $0.backgroundColor = color }
    }
}

/// `DiscoveryListRow`: padding 12, gap 12, hover accent/40, an inset 2px ring on keyboard focus.
public final class DiscoveryRowView: ControlView {
    private let decoration = BoxDecorationLayer()
    private let icon: NSView
    private let iconSize: CGFloat
    private let titleLabel = LabelView()
    private let detailLabel = LabelView()

    public convenience init(icon: IconName, title: String, detail: String) {
        self.init(iconView: IconView(name: icon, size: 16, strokeColor: Themed.color(\.contrastMutedForeground)), iconSize: 16, title: title, detail: detail)
    }

    /// Any leading view, such as the browser's 28px favicon (`PreviewFaviconIcon`).
    public init(iconView: NSView, iconSize: CGFloat, title: String, detail: String) {
        icon = iconView
        self.iconSize = iconSize
        super.init(frame: .zero)
        scalesWhenPressed = false
        decoration.host = self
        decoration.outset = 0
        layer?.addSublayer(decoration)
        titleLabel.text = title
        titleLabel.font = DSFont.ui(14, weight: .medium)
        titleLabel.lineHeight = 20
        titleLabel.color = Themed.color(\.contrastForeground)
        detailLabel.text = detail
        detailLabel.font = DSFont.ui(12)
        detailLabel.lineHeight = 16
        detailLabel.color = Themed.color(\.contrastMutedForeground)
        [self.icon, titleLabel, detailLabel].forEach(addSubview)
        setAccessibilityLabel(title)
        restyle()
    }

    public override func layout() {
        super.layout()
        decoration.layout(boxSize: bounds.size)
        icon.frame = NSRect(x: 12, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize)
        let x: CGFloat = 12 + iconSize + 12, w = max(0, bounds.width - x - 12)
        let top = (bounds.height - 36) / 2
        titleLabel.frame = NSRect(x: x, y: top, width: w, height: 20)
        detailLabel.frame = NSRect(x: x, y: top + 20, width: w, height: 16)
    }

    public override func stateDidChange(from old: State) {
        super.stateDidChange(from: old)
        restyle()
    }

    private func restyle() {
        var box = BoxStyle()
        if state.hovered && state.enabled { box.fill = Themed.color(\.accent, 0.4) }
        if state.focusVisible { box.shadows = [BoxShadow(spread: 2, color: Themed.color(\.ring), inset: true)] }
        decoration.boxStyle = box
    }
}
