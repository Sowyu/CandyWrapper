import AppKit
import DesignSystem

/// `ThreadErrorBanner` (chat/ThreadErrorBanner.tsx): an `Alert` with `surface="glass"` and
/// `controlAlignment="first-line"`, centered at the top of the chat column, 12px below the header
/// (`pt-3`), `w-fit`, at most `min(48rem, 100% - 2rem)` wide. Circle-alert icon, the message
/// clamped to 3 lines with the full text in a tooltip, and a ghost `icon-xs` X ("Dismiss error").
/// Glass (`alert-glass`, index.css:344-372): the background at 80% under a 4% tint of the variant
/// color, over a 12px backdrop blur; border and text keep the variant colors (alert.tsx:22-27).
/// The provider status banner (ProviderStatusBanner.tsx:95-152) is the same alert with an info
/// glyph, a medium `AlertTitle` above the message and an "Open provider setup" link below it.
public final class ThreadErrorBannerView: DSView {
    public var banner: ThreadErrorState.Banner? {
        didSet {
            guard banner != oldValue else { return }
            isHidden = banner == nil
            text.text = banner?.message ?? ""
            title.text = banner?.title ?? ""
            title.isHidden = banner?.title == nil
            setup.isHidden = banner?.setupLink != true
            icon.isHidden = banner?.info == true
            infoIcon.isHidden = banner?.info != true
            close.setAccessibilityLabel(banner?.title.map { _ in "Dismiss provider status" } ?? "Dismiss error")
            tooltip.text = banner?.message ?? ""
            needsDisplay = true
            restyle()
            needsLayout = true
        }
    }
    public var onDismiss: (@MainActor () -> Void)? {
        get { close.action }
        set { close.action = newValue }
    }

    private let blur = BackdropBlurView()
    private let surface = DSView()
    private let tint = CALayer()
    private let icon = IconView(name: .circleAlert)
    private let infoIcon = IconView(name: .info)
    private let title = LabelView("", font: DSFont.ui(14, weight: .medium))
    private let text = TextBlockView()
    /// "Open provider setup" (`InlineButton`).
    public let setup = ButtonView("Open provider setup", variant: .link, size: .xs)
    private let close = ButtonView(nil, icon: .x, variant: .ghost, size: .iconXs)
    private lazy var tooltip = TooltipController.attach(to: text, text: "", placement: PopupPlacement(side: .top, align: .center, sideOffset: 4))

    static let radius: CGFloat = 14
    /// `px-3.5 py-3` plus the 1px border.
    static let padX: CGFloat = 15, padY: CGFloat = 13
    static let line: CGFloat = 20

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isHidden = true
        layer?.masksToBounds = false
        blur.cornerRadius = Self.radius
        addSubview(blur)
        surface.layer?.cornerRadius = Self.radius
        surface.layer?.masksToBounds = true
        surface.layer?.borderWidth = 1
        surface.layer?.addSublayer(tint)
        addSubview(surface)
        addSubview(icon)
        infoIcon.isHidden = true
        addSubview(infoIcon)
        text.font = DSFont.ui(14)
        text.lineHeight = Self.line
        text.maxLines = 3
        // Chromium draws text on backdrop-filter layers without font smoothing.
        text.smoothsFont = false
        addSubview(text)
        title.lineHeight = Self.line
        title.smoothsFont = false
        title.isHidden = true
        addSubview(title)
        setup.isHidden = true
        setup.smoothsFont = false
        addSubview(setup)
        close.setAccessibilityLabel("Dismiss error")
        addSubview(close)
        _ = tooltip
        setAccessibilityRole(.group)
        setAccessibilityRoleDescription("alert")
    }

    /// Text column width at a total width: icon 16 + gap 8, gap 8 + the 24pt button.
    private static func textWidth(_ total: CGFloat) -> CGFloat { max(0, total - 2 * padX - 16 - 8 - 8 - 24) }

    /// `w-fit` up to `maxWidth`.
    public func fittingWidth(max maxWidth: CGFloat) -> CGFloat {
        let column = max(ceil(text.naturalWidth), title.isHidden ? 0 : ceil(title.textWidth), setup.isHidden ? 0 : setup.intrinsicContentSize.width)
        let natural = column + 2 * Self.padX + 16 + 8 + 8 + 24
        return min(maxWidth, natural)
    }

    /// First-line row with an action: `min-h-6 pt-0.5`.
    public func height(forWidth width: CGFloat) -> CGFloat {
        let content = text.height(forWidth: Self.textWidth(width)) + extraHeight
        return 2 * Self.padY + max(24, 2 + content)
    }

    public override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        blur.frame = bounds
        surface.frame = bounds
        tint.frame = surface.bounds
        CATransaction.commit()
        let top = Self.padY + 2, w = Self.textWidth(bounds.width)
        icon.frame = NSRect(x: Self.padX, y: top + (Self.line - 16) / 2, width: 16, height: 16)
        infoIcon.frame = icon.frame
        // `flex-col gap-0.5`: the title, then the description (`flex-col gap-2.5`: text, then the link).
        var y = top
        if !title.isHidden {
            title.frame = NSRect(x: Self.padX + 24, y: y, width: w, height: Self.line)
            y += Self.line + 2
        }
        text.frame = NSRect(x: Self.padX + 24, y: y, width: w, height: text.height(forWidth: w))
        if !setup.isHidden {
            let s = setup.intrinsicContentSize
            setup.frame = NSRect(x: Self.padX + 24, y: text.frame.maxY + 10, width: min(w, s.width), height: Self.line)
        }
        close.frame = NSRect(x: bounds.width - Self.padX - 24, y: top + (Self.line - 24) / 2, width: 24, height: 24)
    }

    /// The title row and the link under the message.
    private var extraHeight: CGFloat { (title.isHidden ? 0 : Self.line + 2) + (setup.isHidden ? 0 : 10 + Self.line) }

    public override func updateLayer() { restyle() }

    private func restyle() {
        let warning = banner?.variant == .warning
        let color: KeyPath<Palette, TokenColor> = warning ? \.warning : \.error
        CATransaction.begin(); CATransaction.setDisableActions(true)
        surface.layer?.backgroundColor = Themed.color(\.background, 0.8).cgColor(in: self)
        tint.backgroundColor = Themed.color(color, 0.04).cgColor(in: self)
        surface.layer?.borderColor = Themed.color(color, 0.32).cgColor(in: self)
        CATransaction.commit()
        icon.strokeColor = Themed.color(color)
        infoIcon.strokeColor = Themed.color(color)
        // `AlertDescription` in the variant: `text-{variant}-foreground/80`.
        text.color = Themed.color(warning ? \.warningForeground : \.errorForeground, 0.8)
        title.color = Themed.color(warning ? \.warningForeground : \.errorForeground)
    }
}
