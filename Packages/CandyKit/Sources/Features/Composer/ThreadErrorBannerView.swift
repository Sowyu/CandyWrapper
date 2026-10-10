import AppKit
import DesignSystem

/// `ThreadErrorBanner` (chat/ThreadErrorBanner.tsx): an `Alert` with `surface="glass"` and
/// `controlAlignment="first-line"`, centered at the top of the chat column, 12px below the header
/// (`pt-3`), `w-fit`, at most `min(48rem, 100% - 2rem)` wide. Circle-alert icon, the message
/// clamped to 3 lines with the full text in a tooltip, and a ghost `icon-xs` X ("Dismiss error").
/// Glass (`alert-glass`, index.css:344-372): the background at 80% under a 4% tint of the variant
/// color, over a 12px backdrop blur; border and text keep the variant colors (alert.tsx:22-27).
public final class ThreadErrorBannerView: DSView {
    public var banner: ThreadErrorState.Banner? {
        didSet {
            guard banner != oldValue else { return }
            isHidden = banner == nil
            text.text = banner?.message ?? ""
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
    private let text = TextBlockView()
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
        text.font = DSFont.ui(14)
        text.lineHeight = Self.line
        text.maxLines = 3
        // Chromium draws text on backdrop-filter layers without font smoothing.
        text.smoothsFont = false
        addSubview(text)
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
        let natural = ceil(text.naturalWidth) + 2 * Self.padX + 16 + 8 + 8 + 24
        return min(maxWidth, natural)
    }

    /// First-line row with an action: `min-h-6 pt-0.5`.
    public func height(forWidth width: CGFloat) -> CGFloat {
        let content = text.height(forWidth: Self.textWidth(width))
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
        text.frame = NSRect(x: Self.padX + 24, y: top, width: w, height: text.height(forWidth: w))
        close.frame = NSRect(x: bounds.width - Self.padX - 24, y: top + (Self.line - 24) / 2, width: 24, height: 24)
    }

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
        // `AlertDescription` in the variant: `text-{variant}-foreground/80`.
        text.color = Themed.color(warning ? \.warningForeground : \.errorForeground, 0.8)
    }
}
