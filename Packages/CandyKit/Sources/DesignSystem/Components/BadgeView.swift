import AppKit

/// T3's `Badge` (`apps/web/src/components/ui/badge.tsx`) as a static span, desktop values.
/// Spec: docs/research/recovered/ui-components-b.md section 6.
public final class BadgeView: DSView {
    public enum Variant: String, CaseIterable, Sendable {
        case `default`, destructive, error, info, outline, secondary, success, warning, label
    }

    public enum Size: String, CaseIterable, Sendable {
        case sm, `default`, lg, control

        /// Height (= min width), inline padding, radius, font px, line-height.
        var metrics: (height: CGFloat, padding: CGFloat, radius: CGFloat, font: CGFloat, line: CGFloat) {
            switch self {
            case .sm: (16, 3, 4, 10, 10)
            case .default: (18, 3, 6, 12, 16)
            case .lg: (22, 5, 6, 14, 20)
            case .control: (24, 7, 8, 12, 16)
            }
        }
    }

    public var variant: Variant = .default { didSet { restyle() } }
    public var size: Size = .default { didSet { restyle(); invalidateIntrinsicContentSize() } }
    public var title: String { didSet { label.text = title; invalidateIntrinsicContentSize() } }
    public var icon: IconName? { didSet { updateIcon() } }
    /// `--label` for the `label` variant.
    public var labelColor: NSColor = .systemBlue { didSet { restyle() } }

    private let decoration = BoxDecorationLayer()
    private let label = LabelView()
    private var iconView: IconView?

    public init(_ title: String, variant: Variant = .default, size: Size = .default, icon: IconName? = nil) {
        self.title = title
        self.variant = variant
        self.size = size
        super.init(frame: .zero)
        decoration.host = self
        decoration.transition = [.shadow] // transition-shadow (badge.tsx:10)
        layer?.addSublayer(decoration)
        layer?.masksToBounds = false
        label.text = title
        label.truncates = false
        addSubview(label)
        self.icon = icon
        updateIcon()
        restyle()
    }

    private var contentWidth: CGFloat {
        let text = title.isEmpty ? 0 : label.textWidth
        guard iconView != nil else { return text }
        return 12 + (title.isEmpty ? 0 : 4 + text)
    }

    public override var intrinsicContentSize: NSSize {
        let m = size.metrics
        let width = max(m.height, contentWidth + 2 * (m.padding + 1))
        // ponytail: Chromium snaps the border box to device pixels; assumes a 2x backing store
        return NSSize(width: (width * 2).rounded() / 2, height: m.height)
    }

    public override func layout() {
        super.layout()
        decoration.layout(boxSize: bounds.size)
        let m = size.metrics
        var x = (bounds.width - contentWidth) / 2
        if let iconView {
            iconView.frame = NSRect(x: x, y: (bounds.height - 12) / 2, width: 12, height: 12)
            x += 16
        }
        let textWidth = title.isEmpty ? 0 : label.textWidth
        label.frame = NSRect(x: x, y: (bounds.height - m.line) / 2, width: textWidth, height: m.line)
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        decoration.setNeedsDisplay()
    }

    private func updateIcon() {
        iconView?.removeFromSuperview()
        iconView = icon.map { IconView(name: $0, size: 12) }
        if let iconView {
            iconView.alphaValue = 0.8  // `[&_svg]:opacity-80`
            addSubview(iconView)
        }
        restyle()
        invalidateIntrinsicContentSize()
    }

    private func restyle() {
        let m = size.metrics
        label.font = DSFont.ui(m.font, weight: .medium)
        label.lineHeight = m.line
        var box = BoxStyle()
        box.radius = m.radius
        box.border = .clear
        let text: NSColor
        switch variant {
        case .default:
            box.fill = Themed.color(\.primary); text = Themed.color(\.primaryForeground)
        case .destructive:
            box.fill = Themed.color(\.destructive); text = Themed.white(1)
        case .error:
            box.fill = Themed.color(light: \.destructive, 0.08, dark: \.destructive, 0.16); text = Themed.color(\.destructiveForeground)
        case .info:
            box.fill = Themed.color(light: \.info, 0.08, dark: \.info, 0.16); text = Themed.color(\.infoForeground)
        case .success:
            box.fill = Themed.color(light: \.success, 0.08, dark: \.success, 0.16); text = Themed.color(\.successForeground)
        case .warning:
            box.fill = Themed.color(light: \.warning, 0.08, dark: \.warning, 0.16); text = Themed.color(\.warningForeground)
        case .outline:
            box.border = Themed.color(\.contrastInput)
            box.fill = Themed.color(light: \.background, 1, dark: \.contrastInput, 0.32)
            text = Themed.color(\.contrastForeground)
        case .secondary:
            box.fill = Themed.color(\.secondary); text = Themed.color(\.contrastSecondaryForeground)
        case .label:
            // color-mix in srgb: --label at 8% / 12% fill, text --label mixed 30% / 45% into the foreground.
            let tint = labelColor
            box.fill = Themed.pick(light: tint.withAlphaComponent(0.08), dark: tint.withAlphaComponent(0.12))
            text = NSColor(name: nil) { appearance in
                var result = tint
                appearance.performAsCurrentDrawingAppearance {
                    let fg = Themed.color(\.contrastForeground).usingColorSpace(.sRGB) ?? .black
                    let t = tint.usingColorSpace(.sRGB) ?? tint
                    result = fg.blended(withFraction: appearance.isDark ? 0.45 : 0.30, of: t) ?? t
                }
                return result
            }
        }
        decoration.boxStyle = box
        label.color = text
        iconView?.strokeColor = text
        needsLayout = true
    }
}
