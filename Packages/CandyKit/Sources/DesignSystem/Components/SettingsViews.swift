import AppKit

/// T3's settings card surfaces (`components/settings/SettingsGroup.tsx`, `settings/settingsLayout.tsx`):
/// `SettingsSection` is a header over a `SettingsGroup` card of `SettingsRow`s. Desktop (`sm:`) values.
/// Spec: docs/research/recovered/ui-components-b.md section 26.

/// `SettingsRow`: title, optional description, and a control column. At 512px and wider
/// (`@min-[32rem]/settings-row`) a two-column grid, otherwise stacked.
public final class SettingsRowView: DSView {
    public var title: String { didSet { titleLabel.text = title } }
    public var detail: String? { didSet { detailText.text = detail ?? ""; detailText.isHidden = detail == nil; invalidateIntrinsicContentSize() } }
    public var control: NSView? {
        didSet { oldValue?.removeFromSuperview(); control.map(addSubview); invalidateIntrinsicContentSize(); needsLayout = true }
    }
    /// `aria-disabled`: opacity .64 (and muted text, which the dimmed foreground approximates).
    public var isDisabled = false { didSet { alphaValue = isDisabled ? 0.64 : 1 } }
    /// The 1px `border-t border-border/50` a divided group gives every row after the first.
    var topBorder = false { didSet { needsDisplay = true; invalidateIntrinsicContentSize() } }

    private let titleLabel = LabelView()
    private let detailText = TextBlockView()
    private let border = CALayer()

    public init(title: String, detail: String? = nil, control: NSView? = nil) {
        self.title = title
        self.detail = detail
        self.control = control
        super.init(frame: .zero)
        titleLabel.text = title
        titleLabel.font = DSFont.ui(14, weight: .medium)
        titleLabel.lineHeight = 20
        titleLabel.color = Themed.color(\.contrastForeground)
        detailText.text = detail ?? ""
        detailText.isHidden = detail == nil
        detailText.font = DSFont.ui(12)
        detailText.lineHeight = 18
        detailText.color = Themed.color(\.contrastMutedForeground, 0.8)
        addSubview(titleLabel)
        addSubview(detailText)
        control.map(addSubview)
        layer?.addSublayer(border)
    }

    static let paddingX: CGFloat = 16, paddingY: CGFloat = 12

    private struct Frames { var title, detail, control: NSRect; var height: CGFloat }

    private func frames(width: CGFloat) -> Frames {
        let top = Self.paddingY + (topBorder ? 1 : 0)
        let inner = max(0, width - 2 * Self.paddingX)
        let controlSize = control.map { c -> NSSize in
            let s = c.intrinsicContentSize
            return NSSize(width: s.width == NSView.noIntrinsicMetric ? c.frame.width : s.width,
                          height: s.height == NSView.noIntrinsicMetric ? c.frame.height : s.height)
        } ?? .zero
        func textHeight(_ w: CGFloat) -> CGFloat {
            20 + (detail == nil ? 0 : 4 + detailText.height(forWidth: min(576, w)))
        }
        if width >= 512 {
            // grid-cols-[minmax(0,1fr)_minmax(10rem,auto)] gap-8 items-center
            let controlColumn = control == nil ? 0 : max(160, controlSize.width)
            let textWidth = max(0, inner - controlColumn - (control == nil ? 0 : 32))
            let th = textHeight(textWidth)
            let rowHeight = max(th, controlSize.height)
            let textY = top + (rowHeight - th) / 2
            return Frames(title: NSRect(x: Self.paddingX, y: textY, width: textWidth, height: 20),
                          detail: NSRect(x: Self.paddingX, y: textY + 24, width: min(576, textWidth), height: th - 24),
                          control: NSRect(x: width - Self.paddingX - controlSize.width, y: top + (rowHeight - controlSize.height) / 2,
                                          width: controlSize.width, height: controlSize.height),
                          height: top + rowHeight + Self.paddingY)
        }
        let th = textHeight(inner)
        let controlY = top + th + 12
        return Frames(title: NSRect(x: Self.paddingX, y: top, width: inner, height: 20),
                      detail: NSRect(x: Self.paddingX, y: top + 24, width: min(576, inner), height: th - 24),
                      control: NSRect(x: Self.paddingX, y: controlY, width: inner, height: controlSize.height),
                      height: (control == nil ? top + th : controlY + controlSize.height) + Self.paddingY)
    }

    public func height(forWidth width: CGFloat) -> CGFloat { frames(width: width).height }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: bounds.width > 0 ? height(forWidth: bounds.width) : NSView.noIntrinsicMetric)
    }

    public override func layout() {
        super.layout()
        let f = frames(width: bounds.width)
        titleLabel.frame = f.title
        detailText.frame = f.detail
        control?.frame = f.control
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        border.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 1)
        border.isHidden = !topBorder
        CATransaction.commit()
    }

    public override func updateLayer() {
        border.backgroundColor = Themed.color(\.contrastBorder, 0.5).cgColor(in: self)
    }
}

/// `SettingsGroup`: the canonical card. 14px radius, border/60, card/40, `shadow-xs/5`, rows divided by border/50.
public final class SettingsGroupView: BoxView {
    public enum Variant: Sendable { case grouped, plain }
    public var rows: [SettingsRowView] {
        didSet { oldValue.forEach { $0.removeFromSuperview() }; rows.forEach(addSubview); restyle(); needsLayout = true }
    }
    public var variant: Variant { didSet { restyle(); needsLayout = true } }

    public init(rows: [SettingsRowView], variant: Variant = .grouped) {
        self.rows = rows
        self.variant = variant
        super.init(frame: .zero)
        rows.forEach(addSubview)
        restyle()
    }

    private func restyle() {
        var box = BoxStyle()
        if variant == .grouped {
            box.radius = 14
            box.border = Themed.color(\.contrastBorder, 0.6)
            box.fill = Themed.color(\.card, 0.4)
            box.shadows = [BoxShadow(y: 1, blur: 2, color: Themed.black(0.05))]
        }
        boxStyle = box
        for (i, row) in rows.enumerated() { row.topBorder = variant == .grouped && i > 0 }
    }

    private var inset: CGFloat { variant == .grouped ? 1 : 0 }
    private var gap: CGFloat { variant == .plain ? 4 : 0 }  // `space-y-1`

    public func height(forWidth width: CGFloat) -> CGFloat {
        rows.reduce(0) { $0 + $1.height(forWidth: width - 2 * inset) } + gap * CGFloat(max(0, rows.count - 1)) + 2 * inset
    }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: bounds.width > 0 ? height(forWidth: bounds.width) : NSView.noIntrinsicMetric)
    }

    public override func layout() {
        super.layout()
        var y = inset
        for row in rows {
            let h = row.height(forWidth: bounds.width - 2 * inset)
            row.frame = NSRect(x: inset, y: y, width: bounds.width - 2 * inset, height: h)
            y += h + gap
        }
    }
}

/// `SettingsSection`: a 28px header (14px regular, foreground at 70%) 10px above its card.
public final class SettingsSectionView: DSView {
    public let group: SettingsGroupView
    public var title: String { didSet { titleLabel.text = title } }
    /// The header's trailing action slot (`min-h-7 min-w-7`).
    public var headerAction: NSView? { didSet { oldValue?.removeFromSuperview(); headerAction.map(addSubview); needsLayout = true } }
    private let titleLabel = LabelView()

    public init(title: String, rows: [SettingsRowView], variant: SettingsGroupView.Variant = .grouped) {
        self.title = title
        group = SettingsGroupView(rows: rows, variant: variant)
        super.init(frame: .zero)
        titleLabel.text = title
        titleLabel.font = DSFont.ui(14)
        titleLabel.lineHeight = 20
        titleLabel.color = Themed.color(\.contrastForeground, 0.7)
        addSubview(titleLabel)
        addSubview(group)
    }

    public func height(forWidth width: CGFloat) -> CGFloat { 28 + 10 + group.height(forWidth: width) }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: bounds.width > 0 ? height(forWidth: bounds.width) : NSView.noIntrinsicMetric)
    }

    public override func layout() {
        super.layout()
        titleLabel.frame = NSRect(x: 16, y: 4, width: bounds.width - 32 - 28 - 16, height: 20)
        if let action = headerAction {
            let s = action.intrinsicContentSize
            action.frame = NSRect(x: bounds.width - 16 - s.width, y: (28 - s.height) / 2, width: s.width, height: s.height)
        }
        group.frame = NSRect(x: 0, y: 38, width: bounds.width, height: group.height(forWidth: bounds.width))
    }
}
