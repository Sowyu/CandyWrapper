import AppKit
import DesignSystem

/// `ThreadErrorBanner` (chat/ThreadErrorBanner.tsx): an `Alert` with `surface="glass"` and
/// `controlAlignment="first-line"`, centered at the top of the chat column, 12px below the header
/// (`pt-3`), `w-fit`, at most `min(48rem, 100% - 2rem)` wide. Circle-alert icon, the message in an
/// `ExpandableText` (settings/ExpandableText.tsx): a JSON error shows its nested message, a long or
/// multi-line one clamps to 3 lines, and "Show full error" / "Show less" swaps in the full text
/// (ThreadErrorBanner.tsx:10-27,79, 02c81ec5ea). A ghost `icon-xs` X ("Dismiss error").
/// Glass (`alert-glass`, index.css:344-372): the background at 80% under a 4% tint of the variant
/// color, over a 12px backdrop blur; border and text keep the variant colors (alert.tsx:22-27).
/// The provider status banner (ProviderStatusBanner.tsx:95-152) is the same alert with an info
/// glyph, a medium `AlertTitle` above the message and an "Open provider setup" link below it.
public final class ThreadErrorBannerView: DSView {
    public var banner: ThreadErrorState.Banner? {
        didSet {
            guard banner != oldValue else { return }
            isHidden = banner == nil
            expanded = false
            applyText()
            title.text = banner?.title ?? ""
            title.isHidden = banner?.title == nil
            setup.isHidden = banner?.setupLink != true
            icon.isHidden = banner?.info == true || banner?.chatGptLimit != nil
            infoIcon.isHidden = banner?.info != true
            openAIIcon.isHidden = banner?.chatGptLimit == nil
            rebuildAction()
            close.setAccessibilityLabel(banner?.title.map { _ in "Dismiss provider status" } ?? "Dismiss error")
            // The provider status banner keeps its hover tooltip; thread errors expand instead.
            tooltip.text = banner?.title == nil ? "" : banner?.message ?? ""
            needsDisplay = true
            restyle()
            needsLayout = true
        }
    }
    public var onDismiss: (@MainActor () -> Void)? {
        get { close.action }
        set { close.action = newValue }
    }
    /// "Copy request for admin" on a ChatGPT Business workspace limit.
    public var onCopyAdminRequest: (@MainActor () -> Void)?
    /// "Manage usage" on a ChatGPT usage limit opens ChatGPT's usage page.
    public var onOpenURL: (@MainActor (URL) -> Void)?

    private let blur = BackdropBlurView()
    private let surface = DSView()
    private let tint = CALayer()
    private let icon = IconView(name: .circleAlert)
    private let infoIcon = IconView(name: .info)
    /// The OpenAI mark of the ChatGPT usage limit face (`size-4 text-foreground!`).
    private let openAIIcon = IconView(name: .brandOpenAI, size: 16)
    /// The ChatGPT face's default `sm` button before the X (ThreadErrorBanner.tsx:110-116).
    private var action: ButtonView?
    private let title = LabelView("", font: DSFont.ui(14, weight: .medium))
    private let text = TextBlockView()
    /// "Open provider setup" (`InlineButton`).
    public let setup = ButtonView("Open provider setup", variant: .link, size: .xs)
    private let close = ButtonView(nil, icon: .x, variant: .ghost, size: .iconXs)
    /// `InlineButton tone="muted"` with `mt-1` under the text.
    private let expand = ExpandTextButton()
    private var expanded = false

    /// `getThreadErrorBannerMessage` (ThreadErrorBanner.tsx:10-27): `{"error":{"message":"..."}}` shows
    /// only the nested message when it isn't blank.
    public static func collapsedMessage(_ error: String) -> String {
        guard let data = error.data(using: .utf8), let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let nested = payload["error"] as? [String: Any], let message = nested["message"] as? String,
              !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return error }
        return message
    }

    /// `canExpand` (ExpandableText.tsx:21).
    public static func canExpand(_ error: String) -> Bool {
        collapsedMessage(error) != error || error.utf16.count > 180 || error.contains("\n")
    }

    private var canExpand: Bool { banner?.title == nil && Self.canExpand(banner?.message ?? "") }

    private func rebuildAction() {
        action?.removeFromSuperview()
        action = nil
        switch banner?.chatGptLimit {
        case .workspace?:
            let b = ButtonView("Copy request for admin", variant: .default, size: .sm)
            b.action = { [weak self] in self?.onCopyAdminRequest?() }
            action = b
        case .usage?:
            action = ChatGptButtons.usage(variant: .default, size: .sm) { [weak self] url in self?.onOpenURL?(url) }
        case nil:
            break
        }
        if let action { addSubview(action) }
    }

    /// The action button and its gap, taken from the text column.
    private var actionSpace: CGFloat { action.map { $0.intrinsicContentSize.width + 8 } ?? 0 }
    private func columnWidth(_ total: CGFloat) -> CGFloat { max(0, Self.textWidth(total) - actionSpace) }
    /// `space-y-1` between the ChatGPT face's two paragraphs; `gap-0.5` under an `AlertTitle`.
    private var titleGap: CGFloat { banner?.chatGptLimit == nil ? 2 : 4 }

    private func applyText() {
        let message = banner?.message ?? ""
        let collapsible = canExpand
        text.text = expanded || banner?.title != nil ? message : Self.collapsedMessage(message)
        // The provider status banner keeps its 3-line clamp.
        text.maxLines = banner?.chatGptLimit == nil && (banner?.title != nil || collapsible && !expanded) ? 3 : 0
        expand.isHidden = !collapsible
        expand.title = expanded ? "Show less" : "Show full error"
        expand.setAccessibilityExpanded(expanded)
    }
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
        openAIIcon.isHidden = true
        addSubview(openAIIcon)
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
        expand.isHidden = true
        expand.action = { [weak self] in
            guard let self else { return }
            expanded.toggle()
            applyText()
            needsLayout = true
            superview?.needsLayout = true
        }
        addSubview(expand)
        _ = tooltip
        setAccessibilityRole(.group)
        setAccessibilityRoleDescription("alert")
    }

    /// Text column width at a total width: icon 16 + gap 8, gap 8 + the 24pt button.
    private static func textWidth(_ total: CGFloat) -> CGFloat { max(0, total - 2 * padX - 16 - 8 - 8 - 24) }

    /// `w-fit` up to `maxWidth`.
    public func fittingWidth(max maxWidth: CGFloat) -> CGFloat {
        let column = max(ceil(text.naturalWidth), title.isHidden ? 0 : ceil(title.textWidth), setup.isHidden ? 0 : setup.intrinsicContentSize.width,
                         expand.isHidden ? 0 : expand.intrinsicContentSize.width)
        let natural = column + 2 * Self.padX + 16 + 8 + 8 + 24 + actionSpace
        return min(maxWidth, natural)
    }

    /// First-line row with an action: `min-h-6 pt-0.5`.
    public func height(forWidth width: CGFloat) -> CGFloat {
        let content = text.height(forWidth: columnWidth(width)) + extraHeight
        return 2 * Self.padY + max(24, 2 + content)
    }

    public override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        blur.frame = bounds
        surface.frame = bounds
        tint.frame = surface.bounds
        CATransaction.commit()
        let top = Self.padY + 2, w = columnWidth(bounds.width)
        icon.frame = NSRect(x: Self.padX, y: top + (Self.line - 16) / 2, width: 16, height: 16)
        infoIcon.frame = icon.frame
        openAIIcon.frame = icon.frame
        // `flex-col gap-0.5`: the title, then the description (`flex-col gap-2.5`: text, then the link).
        var y = top
        if !title.isHidden {
            title.frame = NSRect(x: Self.padX + 24, y: y, width: w, height: Self.line)
            y += Self.line + titleGap
        }
        text.frame = NSRect(x: Self.padX + 24, y: y, width: w, height: text.height(forWidth: w))
        if !expand.isHidden {
            expand.frame = NSRect(x: Self.padX + 24, y: text.frame.maxY + 4, width: min(w, expand.intrinsicContentSize.width), height: Self.line)
        }
        if !setup.isHidden {
            let s = setup.intrinsicContentSize
            setup.frame = NSRect(x: Self.padX + 24, y: text.frame.maxY + 10, width: min(w, s.width), height: Self.line)
        }
        close.frame = NSRect(x: bounds.width - Self.padX - 24, y: top + (Self.line - 24) / 2, width: 24, height: 24)
        if let action {
            let s = action.intrinsicContentSize
            action.frame = NSRect(x: close.frame.minX - 8 - s.width, y: top + (Self.line - s.height) / 2, width: s.width, height: s.height)
        }
    }

    /// The title row and the link under the message.
    private var extraHeight: CGFloat {
        (title.isHidden ? 0 : Self.line + titleGap) + (setup.isHidden ? 0 : 10 + Self.line) + (expand.isHidden ? 0 : 4 + Self.line)
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
        infoIcon.strokeColor = Themed.color(color)
        // `AlertDescription` in the variant: `text-{variant}-foreground/80`.
        text.color = Themed.color(warning ? \.warningForeground : \.errorForeground, 0.8)
        // The ChatGPT face's bold line sits in the description, so it keeps the description's color.
        title.color = Themed.color(warning ? \.warningForeground : \.errorForeground, banner?.chatGptLimit == nil ? 1 : 0.8)
        openAIIcon.strokeColor = Themed.color(\.foreground)
    }
}

/// `InlineButton tone="muted"` (ui/button.tsx:99-113): 14px medium muted text, foreground and underlined
/// on hover.
private final class ExpandTextButton: ControlView {
    private let label = LabelView("", font: DSFont.ui(14, weight: .medium))
    var title: String {
        get { label.text }
        set { label.text = newValue; setAccessibilityLabel(newValue); invalidateIntrinsicContentSize() }
    }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scalesWhenPressed = false
        label.lineHeight = ThreadErrorBannerView.line
        label.smoothsFont = false
        addSubview(label)
        setAccessibilityRole(.button)
        restyle()
    }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize { NSSize(width: ceil(label.textWidth), height: ThreadErrorBannerView.line) }
    override func stateDidChange(from old: State) {
        super.stateDidChange(from: old)
        restyle()
    }
    private func restyle() {
        label.color = Themed.color(state.hoverOrPressed ? \.foreground : \.mutedForeground)
        label.isUnderlined = state.hoverOrPressed
    }
    override func layout() { super.layout(); label.frame = bounds }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
