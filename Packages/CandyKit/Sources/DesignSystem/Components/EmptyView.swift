import AppKit
import QuartzCore

/// T3's `Empty` (`apps/web/src/components/ui/empty.tsx`): icon media with two fanned cards behind it,
/// title, description and optional content, centered. Spec: ui-components-b.md section 13.
/// Padding uses the `md:` value (window 768px and wider).
/// Title and description wrap with `text-wrap: balance` inside the header's `max-w-sm`.
public final class EmptyView: DSView {
    public enum Size: String, CaseIterable, Sendable {
        case `default`, compact, hero
        /// Padding, gap, media bottom margin, title font/line, description font/line, min height.
        var metrics: (padding: CGFloat, gap: CGFloat, mediaGap: CGFloat, title: CGFloat, titleLine: CGFloat,
                      body: CGFloat, bodyLine: CGFloat, minHeight: CGFloat) {
            switch self {
            case .default: (48, 24, 24, 20, 28, 14, 20, 0)
            case .compact: (40, 16, 0, 17, 24, 13, 18, 256)
            case .hero: (48, 24, 24, 30, 36, 14, 20, 0)
            }
        }
    }

    public var size: Size = .default { didSet { restyle(); invalidateIntrinsicContentSize() } }
    /// A `min-h-*` class on the root, such as the Environments list's `min-h-52`. Nil keeps the size's.
    public var minimumHeight: CGFloat? { didSet { invalidateIntrinsicContentSize() } }
    /// The header's text width cap: `max-w-sm` (384), or unbounded for `EmptyHeader className="max-w-none"`.
    public var headerMaxWidth: CGFloat = 384 { didSet { invalidateIntrinsicContentSize(); needsLayout = true } }
    /// `EmptyContent` (buttons and so on), below the header with the size's gap.
    public var content: NSView? {
        didSet { oldValue?.removeFromSuperview(); content.map(addSubview); invalidateIntrinsicContentSize(); needsLayout = true }
    }

    /// A drawing in place of the icon media, as a plain child of the stack (`gap` below it), such as
    /// the Pull Requests page's branch mark. Sized by its intrinsic content size.
    public var illustration: NSView? {
        didSet { oldValue?.removeFromSuperview(); illustration.map(addSubview); invalidateIntrinsicContentSize(); needsLayout = true }
    }

    private let titleLabel = TextBlockView()
    private let descriptionLabel = TextBlockView()
    private let media: MediaView?

    public init(title: String, message: String? = nil, icon: IconName? = nil, size: Size = .default) {
        media = icon.map(MediaView.init)
        super.init(frame: .zero)
        self.size = size
        titleLabel.text = title
        titleLabel.alignment = .center
        titleLabel.balanced = true
        descriptionLabel.balanced = true
        descriptionLabel.text = message ?? ""
        descriptionLabel.alignment = .center
        media.map(addSubview)
        addSubview(titleLabel)
        addSubview(descriptionLabel)
        restyle()
    }

    private var hasMessage: Bool { !descriptionLabel.text.isEmpty }

    /// The description under the title.
    public var message: String? {
        get { hasMessage ? descriptionLabel.text : nil }
        set { descriptionLabel.text = newValue ?? ""; invalidateIntrinsicContentSize(); needsLayout = true }
    }

    /// Header text width: `max-w-sm` inside the padding. Before the first frame, unbounded.
    private func textWidth(_ width: CGFloat) -> CGFloat {
        width > 0 ? min(headerMaxWidth, width - 2 * size.metrics.padding) : .greatestFiniteMagnitude
    }

    private func headerHeight(_ width: CGFloat) -> CGFloat {
        let m = size.metrics, w = textWidth(width)
        return (media == nil ? 0 : 36 + m.mediaGap) + (illustration.map { $0.intrinsicContentSize.height + m.gap } ?? 0)
            + titleLabel.height(forWidth: w)
            + (hasMessage ? 4 + descriptionLabel.height(forWidth: w) : 0)
    }

    private func stackHeight(_ width: CGFloat) -> CGFloat {
        headerHeight(width) + (content.map { size.metrics.gap + $0.intrinsicContentSize.height } ?? 0)
    }

    public func height(forWidth width: CGFloat) -> CGFloat {
        max(minimumHeight ?? size.metrics.minHeight, stackHeight(width) + 2 * size.metrics.padding)
    }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width))
    }

    public override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { invalidateIntrinsicContentSize() }
    }

    public override func layout() {
        super.layout()
        let m = size.metrics
        let width = bounds.width
        var y = ((bounds.height - stackHeight(width)) / 2).rounded()
        if let media {
            media.frame = NSRect(x: ((width - 36) / 2).rounded(), y: y, width: 36, height: 36)
            y += 36 + m.mediaGap
        }
        if let illustration {
            let s = illustration.intrinsicContentSize
            illustration.frame = NSRect(x: ((width - s.width) / 2).rounded(), y: y, width: s.width, height: s.height)
            y += s.height + m.gap
        }
        let textWidth = self.textWidth(width)
        let textX = (width - textWidth) / 2
        let titleHeight = titleLabel.height(forWidth: textWidth)
        titleLabel.frame = NSRect(x: textX, y: y, width: textWidth, height: titleHeight)
        y += titleHeight
        if hasMessage {
            let h = descriptionLabel.height(forWidth: textWidth)
            descriptionLabel.frame = NSRect(x: textX, y: y + 4, width: textWidth, height: h)
            y += 4 + h
        }
        if let content {
            let s = content.intrinsicContentSize
            let w = s.width == NSView.noIntrinsicMetric ? textWidth : min(s.width, 384)
            content.frame = NSRect(x: (width - w) / 2, y: y + m.gap, width: w, height: s.height)
        }
    }

    public override func updateLayer() { restyle() }

    private func restyle() {
        let m = size.metrics
        titleLabel.font = DSFont.ui(m.title, weight: .semibold)
        titleLabel.lineHeight = m.titleLine
        titleLabel.color = Themed.color(\.contrastForeground)
        descriptionLabel.font = DSFont.ui(m.body)
        descriptionLabel.lineHeight = m.bodyLine
        descriptionLabel.color = Themed.color(\.contrastMutedForeground)
        needsLayout = true
    }

    /// `EmptyMedia variant="icon"`: a 36px card with the icon, and two copies fanned out behind it
    /// (scale .84, rotate -10 and 10 degrees around their bottom corners, 2px apart, 1px up).
    final class MediaView: DSView {
        private let cards = [BoxDecorationLayer(), BoxDecorationLayer(), BoxDecorationLayer()]
        private let holders = [CALayer(), CALayer()]
        private let iconView: IconView

        init(icon: IconName) {
            iconView = IconView(name: icon, size: 18)
            super.init(frame: NSRect(x: 0, y: 0, width: 36, height: 36))
            layer?.masksToBounds = false
            for (i, holder) in holders.enumerated() {
                holder.actions = ["position": NSNull(), "bounds": NSNull(), "transform": NSNull(), "anchorPoint": NSNull()]
                holder.addSublayer(cards[i])
                layer?.addSublayer(holder)
            }
            layer?.addSublayer(cards[2])
            cards.forEach { $0.host = self }
            addSubview(iconView)
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for (i, holder) in holders.enumerated() {
                let left = i == 0
                // `bottom-px` with `origin-bottom-left` / `origin-bottom-right`.
                holder.anchorPoint = CGPoint(x: left ? 0 : 1, y: 1)
                holder.bounds = CGRect(x: 0, y: 0, width: 36, height: 36)
                holder.position = CGPoint(x: left ? 0 : 36, y: 35)
                // CSS order: translate, then rotate, then scale. Rotation sign matches CSS in the flipped tree.
                var t = CATransform3DMakeTranslation(left ? -2 : 2, 0, 0)
                t = CATransform3DRotate(t, (left ? -10 : 10) * .pi / 180, 0, 0, 1)
                t = CATransform3DScale(t, 0.84, 0.84, 1)
                holder.transform = t
                cards[i].layout(boxSize: CGSize(width: 36, height: 36))
            }
            cards[2].layout(boxSize: bounds.size)
            CATransaction.commit()
            iconView.frame = NSRect(x: 9, y: 9, width: 18, height: 18)
        }

        override func updateLayer() {
            for (i, card) in cards.enumerated() {
                var box = BoxStyle()
                box.radius = DesignGeometry.radius(8, in: self)
                box.border = Themed.color(\.contrastBorder)
                box.fill = Themed.color(\.card)
                box.backgroundClip = .paddingInLight
                if i == 2 {
                    box.shadows = [BoxShadow(y: 1, blur: 3, color: Themed.black(0.05)),
                                   BoxShadow(y: 1, blur: 2, spread: -1, color: Themed.black(0.05))]
                }
                box.beforeShadows = [BoxShadow(y: 1, color: Themed.pick(light: Themed.black(0.04), dark: .clear)),
                                     BoxShadow(y: -1, color: Themed.pick(light: .clear, dark: Themed.white(0.06)))]
                card.boxStyle = box
                card.setNeedsDisplay()
            }
            iconView.strokeColor = Themed.color(\.contrastForeground)
        }
    }
}
