import AppKit
import DesignSystem
import T3Store

/// One `ComposerBannerStack` item docked over the composer (ComposerBannerStack.tsx:330-385,
/// ComposerBanner.tsx:180-330): a 24pt icon column with a 12pt glyph, the title in medium weight,
/// the description in muted text truncated after it, then ghost `xs` actions and an optional
/// `icon-xs` X. With `compact`, a narrow banner (under 400pt) drops the description. A cut or hidden
/// description gets the "Show notice details" button, a cut title "Show title details" (`NoticeText`,
/// :250-317 and :358-371, 060ac670a9). Used for the
/// project clone notice (ChatView.tsx:2535-2596) and the branch change notice (:7801-7837).
public final class ComposerNoticeBannerView: ComposerBannerView {
    public struct Content: Equatable {
        public var variant: Variant
        public var icon: IconName
        public var title: String
        public var description: String?
        public var actions: [String]
        /// The X's VoiceOver label; T3 falls back to "Dismiss warning" (ComposerBannerStack.tsx:374).
        public var dismissLabel: String?
        /// The item has `onDismiss`: the X shows.
        public var dismissible: Bool
        public var elapsedStartedAt: TimeInterval?
        public var compact: Bool
        /// The item's `priority` in the banner stack.
        public var priority: ComposerBannerStackItem.Priority?
        /// Muted text before the title, in normal weight and never cut ("Branch changed from").
        public var titlePrefix: String?
        /// The title is a `<code>`: monospace, cut at its end.
        public var titleCode: Bool
        /// A tooltip on the title (side top).
        public var titleTooltip: String?
        /// A turning `Spinner` in place of the icon.
        public var spinner: Bool
        /// The icon in `text-error`, like the failed server update.
        public var iconIsError: Bool
        /// The buttons' `title` tooltip.
        public var actionTooltip: String?
        /// A 6pt `bg-foreground` dot in place of the icon, pulsing with `status-pulse` when asked.
        public var dot: Dot?
        public enum Dot: Equatable, Sendable { case still, pulsing }
        /// The description as text and `InlineButton tone="muted"` pieces, written whole into `description`
        /// for the measure and the details popup. While it fits, the pieces show and the links answer `onLink`.
        public var descriptionParts: [DescriptionPart]
        public struct DescriptionPart: Equatable, Sendable {
            public var text: String
            /// The link's VoiceOver label; nil for plain text.
            public var link: String?
            public init(text: String, link: String? = nil) { self.text = text; self.link = link }
        }
        public init(variant: Variant, icon: IconName, title: String, description: String? = nil, actions: [String] = [],
                    dismissLabel: String? = nil, dismissible: Bool? = nil, compact: Bool = false,
                    priority: ComposerBannerStackItem.Priority? = nil, titlePrefix: String? = nil, titleCode: Bool = false,
                    titleTooltip: String? = nil, spinner: Bool = false, iconIsError: Bool = false, actionTooltip: String? = nil,
                    dot: Dot? = nil, elapsedStartedAt: TimeInterval? = nil, descriptionParts: [DescriptionPart] = []) {
            self.variant = variant; self.icon = icon; self.title = title
            self.description = descriptionParts.isEmpty ? description : descriptionParts.map(\.text).joined()
            self.actions = actions; self.dismissLabel = dismissLabel; self.dismissible = dismissible ?? (dismissLabel != nil)
            self.compact = compact; self.priority = priority
            self.titlePrefix = titlePrefix; self.titleCode = titleCode; self.titleTooltip = titleTooltip
            self.spinner = spinner; self.iconIsError = iconIsError; self.actionTooltip = actionTooltip
            self.elapsedStartedAt = elapsedStartedAt
            self.dot = dot; self.descriptionParts = descriptionParts
        }
        /// `aria-label={item.dismissLabel ?? "Dismiss warning"}`.
        public var resolvedDismissLabel: String { dismissLabel ?? "Dismiss warning" }
    }

    private var iconView = IconView(name: .info, size: 12)
    private var spinnerView: SpinnerView?
    private let elapsed = glassLabel(font: SB.tabular(12), color: Themed.color(\.mutedForeground), lineHeight: 24)
    private let prefix = glassLabel(font: DSFont.ui(12), color: Themed.color(\.mutedForeground), lineHeight: 24)
    private let title = glassLabel(font: DSFont.ui(12, weight: .medium), color: Themed.color(\.foreground), lineHeight: 24)
    private let detail = glassLabel(font: DSFont.ui(12), color: Themed.color(\.mutedForeground), lineHeight: 24)
    /// "Show notice details": shown only while the description is cut or hidden.
    public let detailsButton = ButtonView(nil, icon: .info, variant: .ghostMuted, size: .iconXs)
    /// "Show title details": shown only while the title is cut.
    public let titleDetailsButton = ButtonView(nil, icon: .info, variant: .ghostMuted, size: .iconXs)
    private var titleTip: TooltipController?
    private var buttons: [ButtonView] = []
    private var dotView: WorkDotView?
    private var partViews: [NSView] = []
    /// A link in `content.descriptionParts`, by its index there.
    public var onLink: ((Int) -> Void)?
    public var disabledActions: Set<Int> = [] { didSet { updateActionAvailability() } }
    private func updateActionAvailability() {
        for (index, button) in buttons.enumerated() { button.isEnabled = !disabledActions.contains(index) }
    }
    private let dismiss = ButtonView(nil, icon: .x, variant: .ghost, size: .iconXs)
    public override var dismissControl: ButtonView? { dismiss.isHidden ? nil : dismiss }
    public private(set) var content: Content?
    /// An action button by its index in `content.actions`, or the X (nil).
    public var onAction: ((Int?) -> Void)?
    /// Set by the banner stack: the X asks it to play the exit, which then calls `onAction(nil)`.
    public var onDismissRequest: (() -> Void)?

    public init() {
        super.init(variant: .neutral)
        dismiss.iconSize = 14
        dismiss.action = { [weak self] in
            if let request = self?.onDismissRequest { request() } else { self?.onAction?(nil) }
        }
        detailsButton.iconSize = 14
        detailsButton.isHidden = true
        detailsButton.setAccessibilityLabel("Show notice details")
        // `PopoverTrigger openOnHover`: base-ui opens a hover popover after 300ms; a click opens it at once.
        let tip = TooltipController.attach(to: detailsButton, text: "", delay: 0.3)
        tip.content = { [weak self] in NoticeDetailsPopupView(text: self?.content?.description ?? "") }
        detailsButton.action = { [weak tip] in tip?.show(instant: true) }
        titleDetailsButton.iconSize = 14
        titleDetailsButton.isHidden = true
        titleDetailsButton.setAccessibilityLabel("Show title details")
        let titleDetails = TooltipController.attach(to: titleDetailsButton, text: "", delay: 0.3)
        titleDetails.content = { [weak self] in NoticeDetailsPopupView(text: self?.content?.title ?? "") }
        titleDetailsButton.action = { [weak titleDetails] in titleDetails?.show(instant: true) }
        prefix.isHidden = true
        for v in [iconView, elapsed, prefix, title, detail, detailsButton, titleDetailsButton, dismiss] as [NSView] { addSubview(v) }
        setAccessibilityRole(.group)
        setAccessibilityRoleDescription("alert")
    }

    public func apply(_ content: Content) {
        guard content != self.content else { return }
        self.content = content
        variant = content.variant
        iconView.removeFromSuperview()
        iconView = IconView(name: content.icon, size: 12)
        iconView.strokeColor = content.iconIsError ? Themed.base("error") : Themed.color(\.mutedForeground)
        iconView.isHidden = content.spinner || content.dot != nil
        addSubview(iconView)
        if let dot = content.dot {
            let view = dotView ?? WorkDotView()
            view.pulses = dot == .pulsing
            if view.superview == nil { addSubview(view) }
            dotView = view
        } else {
            dotView?.removeFromSuperview()
            dotView = nil
        }
        partViews.forEach { $0.removeFromSuperview() }
        partViews = content.descriptionParts.enumerated().map { index, part in
            guard let link = part.link else {
                let label = glassLabel(part.text, font: DSFont.ui(12), color: Themed.color(\.mutedForeground), lineHeight: 24)
                addSubview(label)
                return label
            }
            let button = ThreadStatusLineAction()
            button.label.text = part.text
            button.label.lineHeight = 24
            button.label.smoothsFont = false
            button.setAccessibilityLabel(link)
            button.action = { [weak self] in self?.onLink?(index) }
            addSubview(button)
            return button
        }
        if content.spinner {
            let spinner = spinnerView ?? SpinnerView(size: .xs)
            spinner.color = Themed.color(\.mutedForeground)
            if spinner.superview == nil { addSubview(spinner) }
            spinnerView = spinner
        } else {
            spinnerView?.removeFromSuperview()
            spinnerView = nil
        }
        prefix.text = content.titlePrefix ?? ""
        prefix.isHidden = content.titlePrefix == nil
        title.color = quietTimelineLine ? Themed.color(\.mutedForeground) : Themed.color(\.foreground)
        title.text = content.title
        title.font = content.titleCode ? DSFont.mono(12, weight: .medium) : DSFont.ui(12, weight: .medium)
        if let tooltip = content.titleTooltip {
            if let titleTip { titleTip.text = tooltip } else { titleTip = TooltipController.attach(to: title, text: tooltip) }
        } else {
            titleTip?.text = ""
        }
        detail.text = content.description ?? ""
        buttons.forEach { $0.removeFromSuperview() }
        buttons = content.actions.enumerated().map { index, label in
            let b = ButtonView(label, variant: .ghost, size: .xs)
            b.smoothsFont = false
            b.toolTip = content.actionTooltip
            b.action = { [weak self] in self?.onAction?(index) }
            addSubview(b)
            return b
        }
        tickElapsed()
        updateActionAvailability()
        dismiss.isHidden = !content.dismissible
        dismiss.setAccessibilityLabel(content.resolvedDismissLabel)
        needsLayout = true
    }

    private func tickElapsed() {
        guard let start = content?.elapsedStartedAt else {
            elapsed.isHidden = true
            LabelClock.shared.cancel(self)
            return
        }
        elapsed.isHidden = false
        elapsed.text = formatDuration(max(1_000, (Date().timeIntervalSince1970 - start) * 1_000))
        needsLayout = true
        if window != nil { LabelClock.shared.schedule(self, in: 1) { [weak self] in self?.tickElapsed() } }
        else { LabelClock.shared.cancel(self) }
    }
    public override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); tickElapsed(); LabelClock.shared.visibilityChanged() }
    public override func viewDidUnhide() { super.viewDidUnhide(); tickElapsed(); LabelClock.shared.visibilityChanged() }

    /// `py-1.25` around the 24pt row, plus the overlap under the composer.
    public static let height: CGFloat = 5 + 24 + 5 + ComposerBannerView.overlap

    /// Redesign's pill: as wide as the row's content with nothing cut, 4 in from each side plus 6 after the text.
    public var pillWidth: CGFloat {
        var w: CGFloat = 4 + 24 + 4
        if !prefix.isHidden { w += ceil(prefix.textWidth) + 6 }
        w += ceil(title.textWidth) + 1
        if !detail.text.isEmpty { w += 4 + ceil(detail.textWidth) + 2 }
        for b in buttons { w += 4 + b.intrinsicContentSize.width }
        if !dismiss.isHidden { w += 4 + dismiss.intrinsicContentSize.width }
        return ceil(w + 6 + 4)
    }

    public override func layout() {
        super.layout()
        // Floating the row sits in the middle: 5 in T3's 34pt card, 2 in Redesign's 28pt pill.
        let rowY: CGFloat = placement == .floating ? ((bounds.height - 24) / 2).rounded() : 5
        iconView.frame = NSRect(x: 4 + 6, y: rowY + 6, width: 12, height: 12)
        spinnerView?.frame = iconView.frame
        dotView?.frame = NSRect(x: 4 + 9, y: rowY + 9, width: 6, height: 6)
        var right = bounds.width - 4
        for b in ([dismiss].filter { !$0.isHidden } + buttons.reversed()) {
            let s = b.intrinsicContentSize
            right -= s.width
            b.frame = NSRect(x: right, y: rowY + (24 - s.height) / 2, width: s.width, height: s.height)
            right -= 4
        }
        if !elapsed.isHidden {
            let width = ceil(elapsed.textWidth)
            right -= width
            elapsed.frame = NSRect(x: right, y: rowY, width: width, height: 24)
            right -= 8
        }
        var x: CGFloat = 4 + 24 + 4
        if !prefix.isHidden {
            // `shrink-0` prefix, `gap-1.5` to the title.
            let w = ceil(prefix.textWidth)
            prefix.frame = NSRect(x: x, y: rowY, width: min(w, max(0, right - x)), height: 24)
            x = ((x + w + 6) * 2).rounded() / 2
        }
        // A cut title makes room for its details button, `gap-1` after it; the measure leaves the
        // button's own width out, so it can't keep itself shown.
        let titleCut = ceil(title.textWidth) + 1 > max(0, right - x)
        titleDetailsButton.isHidden = !titleCut
        let titleWidth = titleCut ? max(0, right - x - 4 - 24) : ceil(title.textWidth) + 1
        title.frame = NSRect(x: x, y: rowY, width: titleWidth, height: 24)
        if titleCut {
            titleDetailsButton.frame = NSRect(x: x + titleWidth + 4, y: rowY, width: 24, height: 24)
            // ponytail: T3 keeps a zero-width description with its own details button; add it if a cut title with a description shows up
            detail.isHidden = true
            detailsButton.isHidden = true
            partViews.forEach { $0.isHidden = true }
            return
        }
        // `gap-1`; a compact banner hides the description under 400pt (`@max-[400px]:sr-only`).
        let hidden = content?.compact == true && bounds.width < 400
        // The description starts `gap-1` after the title's text, on a device pixel.
        let dx = ((x + min(title.textWidth, titleWidth) + 4) * 2).rounded() / 2
        let room = max(0, right - dx)
        // `NoticeDescription`'s measure: the button shows when the text needs more than all the room.
        let showDetails = !detail.text.isEmpty && (hidden || detail.textWidth > room)
        detail.isHidden = detail.text.isEmpty || hidden
        detailsButton.isHidden = !showDetails
        if showDetails {
            let bx = hidden ? dx : right - 24
            detailsButton.frame = NSRect(x: bx, y: rowY, width: 24, height: 24)
        }
        detail.frame = NSRect(x: dx, y: rowY, width: showDetails ? max(0, room - 24 - 4) : room, height: 24)
        // The pieces show while the whole description fits; a cut one reads as plain text.
        let showParts = !partViews.isEmpty && !detail.isHidden && !showDetails
        if showParts { detail.isHidden = true }
        var px = dx
        for view in partViews {
            view.isHidden = !showParts
            let width = (view as? ThreadStatusLineAction)?.preferredWidth ?? ceil((view as? LabelView)?.textWidth ?? 0)
            view.frame = NSRect(x: px, y: rowY, width: width, height: 24)
            px += width
        }
    }
}

/// The "Notice details" popup (ComposerBannerStack.tsx:296-313): a `PopoverPopup tooltipStyle` with the
/// full description, wrapping and balanced, at most 30rem wide.
// ponytail: clips past 24rem tall instead of T3's ComposerBanner.Scroll; add a ScrollAreaView if a description gets that long
final class NoticeDetailsPopupView: DSView, PopupContent {
    private let decoration = BoxDecorationLayer()
    private let text = TextBlockView()
    static let maxContentWidth: CGFloat = 480 - 16 - 2
    static let maxHeight: CGFloat = 384
    private let maxContentWidth: CGFloat

    init(text value: String, maxWidth: CGFloat = 480, label: String = "Notice details") {
        maxContentWidth = maxWidth - 16 - 2
        super.init(frame: .zero)
        decoration.host = self
        decoration.outset = 16
        layer?.addSublayer(decoration)
        layer?.masksToBounds = false
        var box = PopupSurface.glass.box(radius: 8, beforeLine: true)
        // `tooltipStyle`: `shadow-md/5` in place of the popover's deep drop shadow.
        box.shadows = [BoxShadow(y: 4, blur: 6, spread: -1, color: Themed.black(0.05)),
                       BoxShadow(y: 2, blur: 4, spread: -2, color: Themed.black(0.05))]
        decoration.boxStyle = box
        text.text = value
        text.font = DSFont.ui(12)
        text.lineHeight = 16
        text.balanced = true
        text.color = Themed.color(\.contrastPopoverForeground)
        addSubview(text)
        setAccessibilityRole(.group)
        setAccessibilityLabel(label)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private var contentWidth: CGFloat { min(maxContentWidth, ceil(text.naturalWidth) + 1) }

    var popupSize: CGSize {
        let w = contentWidth
        // Viewport `py-1 px-2` plus the 1px border.
        return CGSize(width: w + 16 + 2, height: min(Self.maxHeight, text.height(forWidth: w) + 8 + 2))
    }

    override var intrinsicContentSize: NSSize { popupSize }

    override func layout() {
        super.layout()
        decoration.layout(boxSize: bounds.size)
        let w = bounds.width - 18
        text.frame = NSRect(x: 9, y: 5, width: w, height: max(0, min(text.height(forWidth: w), bounds.height - 10)))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        decoration.setNeedsDisplay()
    }
}

/// `size-1.5 rounded-full bg-foreground`, with `motion-safe:animate-status-pulse` while the work holds the
/// thread (ThreadActivityBanners.tsx:111-118). The pulse runs in the render server and stops off screen.
final class WorkDotView: DSView {
    var pulses = false {
        didSet {
            guard pulses != oldValue else { return }
            if !pulses { layer?.removeAnimation(forKey: "pulse") }
            loop.update()
        }
    }
    private lazy var loop = LoopingAnimation(view: self, key: "pulse", layer: { [weak self] in self?.pulses == true ? self?.layer : nil }) {
        TerminalStatusGlyph.pulse()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(false)
    }

    override func layout() { super.layout(); layer?.cornerRadius = bounds.height / 2 }
    override func updateLayer() { layer?.backgroundColor = Themed.color(\.foreground).cgColor }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); loop.windowChanged() }
    override func viewDidHide() { super.viewDidHide(); loop.update() }
    override func viewDidUnhide() { super.viewDidUnhide(); loop.update() }
}
