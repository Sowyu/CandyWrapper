import AppKit

/// T3's `Alert` (`apps/web/src/components/ui/alert.tsx`) with centered control alignment:
/// icon, title over description, optional actions. Spec: ui-components-b.md section 7.
/// Width comes from the frame; height from `intrinsicContentSize`.
/// ponytail: title and description are one line each and the glass surface is not drawn;
/// add wrapping when an alert shows long copy, and glass with the other glass surfaces.
public final class AlertView: DSView {
    public enum Variant: String, CaseIterable, Sendable { case `default`, sidebar, error, info, success, warning }

    public var variant: Variant = .default { didSet { restyle(); invalidateIntrinsicContentSize() } }
    public var icon: IconName? { didSet { updateIcon() } }
    public var title: String? { didSet { titleLabel.text = title ?? ""; invalidateIntrinsicContentSize(); needsLayout = true } }
    public var message: String? { didSet { descriptionLabel.text = message ?? ""; invalidateIntrinsicContentSize(); needsLayout = true } }
    /// `AlertAction` children, laid out right with a 4px gap.
    public var actions: [NSView] = [] {
        didSet { oldValue.forEach { $0.removeFromSuperview() }; actions.forEach(addSubview); invalidateIntrinsicContentSize(); needsLayout = true }
    }

    private let decoration = BoxDecorationLayer()
    private let titleLabel = LabelView()
    private let descriptionLabel = LabelView()
    private var iconView: IconView?

    public convenience init(_ title: String?, message: String? = nil, icon: IconName? = nil, variant: Variant = .default) {
        self.init(frame: .zero)
        self.variant = variant
        self.title = title
        titleLabel.text = title ?? ""
        self.message = message
        descriptionLabel.text = message ?? ""
        self.icon = icon
        updateIcon()
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        decoration.host = self
        layer?.addSublayer(decoration)
        layer?.masksToBounds = false
        addSubview(titleLabel)
        addSubview(descriptionLabel)
        setAccessibilityRole(.group)
        setAccessibilityRoleDescription("alert")
        restyle()
    }

    private var sidebar: Bool { variant == .sidebar }
    /// Padding (x, y), line height.
    private var metrics: (px: CGFloat, py: CGFloat, line: CGFloat) { sidebar ? (8, 6, 16) : (14, 12, 20) }
    private var hasTitle: Bool { !(title?.isEmpty ?? true) }
    private var hasMessage: Bool { !(message?.isEmpty ?? true) }

    private var contentHeight: CGFloat {
        let lines = (hasTitle ? 1 : 0) + (hasMessage ? 1 : 0)
        return CGFloat(lines) * metrics.line + (lines == 2 ? 2 : 0)
    }

    private var rowHeight: CGFloat {
        max(contentHeight, iconView == nil ? 0 : 16, actions.map(\.intrinsicContentSize.height).max() ?? 0)
    }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: rowHeight + 2 * (metrics.py + 1))
    }

    public override func layout() {
        super.layout()
        decoration.layout(boxSize: bounds.size)
        let m = metrics
        let top = m.py + 1, rowH = rowHeight
        var x = m.px + 1
        var right = bounds.width - m.px - 1
        if let iconView {
            iconView.frame = NSRect(x: x, y: top + (rowH - 16) / 2, width: 16, height: 16)
            x += 16 + 8
        }
        for action in actions.reversed() {
            let size = action.intrinsicContentSize
            action.frame = NSRect(x: right - size.width, y: top + (rowH - size.height) / 2, width: size.width, height: size.height)
            right -= size.width + 4
        }
        if !actions.isEmpty { right += 4 - 8 }
        var y = top + (rowH - contentHeight) / 2
        if hasTitle {
            titleLabel.frame = NSRect(x: x, y: y, width: right - x, height: m.line)
            y += m.line + 2
        }
        descriptionLabel.frame = NSRect(x: x, y: y, width: hasMessage ? right - x : 0, height: m.line)
    }

    private func updateIcon() {
        iconView?.removeFromSuperview()
        iconView = icon.map { IconView(name: $0) }
        iconView.map(addSubview)
        restyle()
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    public override func updateLayer() { restyle() }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        decoration.setNeedsDisplay()
    }

    private func restyle() {
        let m = metrics
        titleLabel.font = DSFont.ui(sidebar ? 11 : 14, weight: .medium)
        descriptionLabel.font = DSFont.ui(sidebar ? 11 : 14)
        titleLabel.lineHeight = m.line
        descriptionLabel.lineHeight = m.line

        var box = BoxStyle()
        box.radius = sidebar ? 10 : 14
        let cardFg = Themed.color(\.contrastCardForeground)
        var text = cardFg, description = Themed.color(\.contrastMutedForeground), iconColor = Themed.color(\.contrastMutedForeground)
        switch variant {
        case .default:
            box.border = Themed.color(\.contrastBorder)
            box.fill = Themed.color(light: \.background, 0, dark: \.contrastInput, 0.32)
        case .sidebar:
            box.border = Themed.color(\.contrastSidebarBorder)
            box.fill = Themed.color(\.sidebarControlSurface)
            description = Themed.color(\.contrastSidebarMutedForeground)
            iconColor = cardFg
        case .error:
            box.border = Themed.color(\.error, 0.32)
            box.fill = Themed.color(\.errorSurface)
            text = Themed.color(\.errorForeground)
            description = Themed.color(\.errorForeground, 0.8)
            iconColor = Themed.color(\.error)
        case .info, .success:
            let key: KeyPath<Palette, TokenColor> = variant == .info ? \.info : \.success
            box.border = Themed.color(key, 0.32)
            box.fill = Themed.color(key, 0.04)
            iconColor = Themed.color(key)
        case .warning:
            box.border = Themed.color(\.warning, 0.32)
            box.fill = Themed.color(\.warningSurface)
            text = Themed.color(\.warningForeground)
            description = Themed.color(\.warningForeground, 0.8)
            iconColor = Themed.color(\.warning)
        }
        decoration.boxStyle = box
        titleLabel.color = text
        descriptionLabel.color = description
        iconView?.strokeColor = iconColor
        needsLayout = true
    }
}
