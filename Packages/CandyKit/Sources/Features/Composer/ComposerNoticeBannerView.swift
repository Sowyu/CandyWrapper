import AppKit
import DesignSystem

/// One `ComposerBannerStack` item docked over the composer (ComposerBannerStack.tsx:330-370,
/// ComposerBanner.tsx:180-330): a 24pt icon column with a 12pt glyph, the title in medium weight,
/// the description in muted text truncated after it, then ghost `xs` actions and an optional
/// `icon-xs` X. With `compact`, a narrow banner (under 400pt) drops the description. Used for the
/// project clone notice (ChatView.tsx:2535-2596).
public final class ComposerNoticeBannerView: ComposerBannerView {
    public struct Content: Equatable {
        public var variant: Variant
        public var icon: IconName
        public var title: String
        public var description: String?
        public var actions: [String]
        public var dismissLabel: String?
        public var compact: Bool
        public init(variant: Variant, icon: IconName, title: String, description: String? = nil, actions: [String] = [],
                    dismissLabel: String? = nil, compact: Bool = false) {
            self.variant = variant; self.icon = icon; self.title = title; self.description = description
            self.actions = actions; self.dismissLabel = dismissLabel; self.compact = compact
        }
    }

    private var iconView = IconView(name: .info, size: 12)
    private let title = glassLabel(font: DSFont.ui(12, weight: .medium), color: Themed.color(\.foreground), lineHeight: 24)
    private let detail = glassLabel(font: DSFont.ui(12), color: Themed.color(\.mutedForeground), lineHeight: 24)
    private var buttons: [ButtonView] = []
    public var disabledActions: Set<Int> = [] { didSet { updateActionAvailability() } }
    private func updateActionAvailability() {
        for (index, button) in buttons.enumerated() { button.isEnabled = !disabledActions.contains(index) }
    }
    private let dismiss = ButtonView(nil, icon: .x, variant: .ghost, size: .iconXs)
    public private(set) var content: Content?
    /// An action button by its index in `content.actions`, or the X (nil).
    public var onAction: ((Int?) -> Void)?

    public init() {
        super.init(variant: .neutral)
        dismiss.iconSize = 14
        dismiss.action = { [weak self] in self?.onAction?(nil) }
        for v in [iconView, title, detail, dismiss] as [NSView] { addSubview(v) }
        setAccessibilityRole(.group)
        setAccessibilityRoleDescription("alert")
    }

    public func apply(_ content: Content) {
        guard content != self.content else { return }
        self.content = content
        variant = content.variant
        iconView.removeFromSuperview()
        iconView = IconView(name: content.icon, size: 12)
        iconView.strokeColor = Themed.color(\.mutedForeground)
        addSubview(iconView)
        title.text = content.title
        detail.text = content.description ?? ""
        buttons.forEach { $0.removeFromSuperview() }
        buttons = content.actions.enumerated().map { index, label in
            let b = ButtonView(label, variant: .ghost, size: .xs)
            b.smoothsFont = false
            b.action = { [weak self] in self?.onAction?(index) }
            addSubview(b)
            return b
        }
        updateActionAvailability()
        dismiss.isHidden = content.dismissLabel == nil
        dismiss.setAccessibilityLabel(content.dismissLabel ?? "")
        needsLayout = true
    }

    /// `py-1.25` around the 24pt row, plus the overlap under the composer.
    public static let height: CGFloat = 5 + 24 + 5 + ComposerBannerView.overlap

    public override func layout() {
        super.layout()
        let rowY: CGFloat = 5
        iconView.frame = NSRect(x: 4 + 6, y: rowY + 6, width: 12, height: 12)
        var right = bounds.width - 4
        for b in ([dismiss].filter { !$0.isHidden } + buttons.reversed()) {
            let s = b.intrinsicContentSize
            right -= s.width
            b.frame = NSRect(x: right, y: rowY + (24 - s.height) / 2, width: s.width, height: s.height)
            right -= 4
        }
        let x: CGFloat = 4 + 24 + 4
        let titleWidth = min(ceil(title.textWidth) + 1, max(0, right - x))
        title.frame = NSRect(x: x, y: rowY, width: titleWidth, height: 24)
        // `gap-1`; a compact banner hides the description under 400pt (`@max-[400px]:sr-only`).
        let hideDetail = detail.text.isEmpty || (content?.compact == true && bounds.width < 400)
        detail.isHidden = hideDetail
        let dx = title.frame.maxX + 4
        detail.frame = NSRect(x: dx, y: rowY, width: max(0, right - dx), height: 24)
    }
}
