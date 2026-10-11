import AppKit

/// The popup of T3's `Dialog`, `AlertDialog` and `Sheet` (`dialog.tsx`, `alert-dialog.tsx`, `sheet.tsx`):
/// header (title, description), optional panel content, optional footer, and the close button.
/// Spec: ui-components-a.md sections 17 to 19, desktop (`sm:`) values. Present it with `ModalHost`.
/// Width comes from the frame (`preferredWidth(in:)` gives T3's); height from `height(forWidth:)`.
open class DialogView: DSView {
    public enum Kind: Equatable, Sendable {
        case dialog, alertDialog
        case sheet(SheetSide)
    }
    public enum SheetSide: String, CaseIterable, Sendable { case right, left, top, bottom }
    public enum FooterVariant: String, Sendable { case `default`, bare }

    public let kind: Kind
    public var title: String { didSet { titleText.text = title; changed() } }
    public var message: String? { didSet { messageText.text = message ?? ""; changed() } }
    /// `DialogPanel` children, stacked 16px apart at the panel width.
    public var panelContent: [NSView] = [] {
        didSet { oldValue.forEach { $0.removeFromSuperview() }; panelContent.forEach(addSubview); changed() }
    }
    /// Footer buttons, left to right as in the markup; the row is aligned to the end.
    public var footerButtons: [NSView] = [] {
        didSet { oldValue.forEach { $0.removeFromSuperview() }; footerButtons.forEach(addSubview); changed() }
    }
    public var footerVariant: FooterVariant = .default { didSet { changed() } }
    /// The first this many footer buttons sit at the start of the row (`sm:mr-auto` on the last of them).
    public var footerLeadingCount = 0 { didSet { changed() } }
    public var showsCloseButton: Bool { didSet { closeButton.isHidden = !showsCloseButton } }
    /// The popup's `max-w-*` for dialogs (`max-w-lg` by default; Add Environment uses `sm:max-w-3xl`).
    public var maxWidth: CGFloat = 512
    /// Sheet `variant="inset"`: rounded and bordered all round, 16px from the viewport edges.
    public var isInset = false { didSet { restyle(); changed() } }
    /// Called by the close button. `ModalHost` sets it.
    public var onClose: (@MainActor () -> Void)? {
        get { closeButton.action }
        set { closeButton.action = newValue }
    }

    private let decoration = BoxDecorationLayer()
    private let footerLayer = BoxDecorationLayer()
    private let titleText = TextBlockView()
    private let messageText = TextBlockView()
    private let closeButton = ButtonView(nil, icon: .x, variant: .ghost, size: .icon)
    private let panelDocument = DSView()
    private lazy var panelScroll = ScrollAreaView(documentView: panelDocument, scrollFade: true)

    public init(kind: Kind = .dialog, title: String, message: String? = nil) {
        self.kind = kind
        self.title = title
        self.message = message
        showsCloseButton = kind != .alertDialog
        super.init(frame: .zero)
        layer?.masksToBounds = false
        decoration.host = self
        decoration.outset = 112 // 0 24px 72px -20px
        footerLayer.host = self
        layer?.addSublayer(decoration)
        layer?.addSublayer(footerLayer)
        titleText.text = title
        messageText.text = message ?? ""
        titleText.font = DSFont.ui(20, weight: .semibold)
        titleText.lineHeight = 20 // `leading-none`
        messageText.font = DSFont.ui(14)
        messageText.lineHeight = 20
        addSubview(titleText)
        addSubview(messageText)
        closeButton.isHidden = !showsCloseButton
        closeButton.setAccessibilityLabel("Close")
        addSubview(closeButton)
        setAccessibilityRole(.group)
        setAccessibilityRoleDescription(kind == .alertDialog ? "alert dialog" : "dialog")
        setAccessibilityLabel(title)
        restyle()
    }

    private var isSheet: Bool { if case .sheet = kind { true } else { false } }
    private var hasMessage: Bool { !(message?.isEmpty ?? true) }
    private var hasFooter: Bool { !footerButtons.isEmpty }
    /// Border widths: dialogs and inset sheets have all four; edge sheets only the inner edge.
    private var borders: NSEdgeInsets {
        guard case .sheet(let side) = kind, !isInset else { return NSEdgeInsets(top: 1, left: 1, bottom: 1, right: 1) }
        switch side {
        case .right: return NSEdgeInsets(top: 0, left: 1, bottom: 0, right: 0)
        case .left: return NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 1)
        case .top: return NSEdgeInsets(top: 0, left: 0, bottom: 1, right: 0)
        case .bottom: return NSEdgeInsets(top: 1, left: 0, bottom: 0, right: 0)
        }
    }

    private func changed() {
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    /// T3's popup width in a viewport: dialogs `max-w-lg` inside 16px padding; side sheets
    /// `calc(100% - 48px)` up to `max-w-md`; top and bottom sheets the full width.
    public func preferredWidth(in viewport: CGSize) -> CGFloat {
        switch kind {
        case .dialog, .alertDialog: return min(maxWidth, viewport.width - 32)
        case .sheet(let side):
            let inset: CGFloat = isInset ? 32 : 0
            return side == .left || side == .right ? min(448, viewport.width - inset - 48) : viewport.width - inset
        }
    }

    private struct Frames {
        var title = CGRect.zero, message = CGRect.zero, panel: [CGRect] = [], footer = CGRect.zero, buttons: [CGRect] = []
        var height: CGFloat = 0
    }

    private func frames(width: CGFloat) -> Frames {
        var f = Frames()
        let b = borders
        let inner = width - b.left - b.right
        var y = b.top + 24
        // Header: `flex flex-col gap-2 p-6`, bottom padding 12 when a panel follows.
        let textWidth = inner - 48
        let titleHeight = titleText.height(forWidth: textWidth)
        f.title = CGRect(x: b.left + 24, y: y, width: textWidth, height: titleHeight)
        y += titleHeight
        if hasMessage {
            let h = messageText.height(forWidth: textWidth)
            f.message = CGRect(x: b.left + 24, y: y + 8, width: textWidth, height: h)
            y += 8 + h
        }
        y += panelContent.isEmpty ? 24 : 12
        if !panelContent.isEmpty {
            // Panel: `space-y-4 p-6`, top padding 4 under a header, bottom 4 above a bare footer.
            y += 4
            for (i, view) in panelContent.enumerated() {
                view.setFrameSize(NSSize(width: textWidth, height: view.frame.height))
                let h = view.intrinsicContentSize.height
                f.panel.append(CGRect(x: b.left + 24, y: y, width: textWidth, height: h))
                y += h + (i == panelContent.count - 1 ? 0 : 16)
            }
            y += hasFooter && footerVariant == .bare ? 4 : 24
        }
        if hasFooter {
            // Footer: `px-6 py-4` row aligned to the end with an 8px gap; alert dialog's bare footer is `pb-6` only.
            let alertBare = kind == .alertDialog && footerVariant == .bare
            let top: CGFloat = alertBare ? 0 : 16, bottom: CGFloat = alertBare ? 24 : 16
            let sizes = footerButtons.map(\.intrinsicContentSize)
            let rowHeight = sizes.map(\.height).max() ?? 0
            let footerTop = y
            var x = width - b.right - 24
            for (i, s) in sizes.enumerated().reversed() {
                if i < footerLeadingCount {
                    // `sm:mr-auto`: the leading buttons sit at the start.
                    let lead = sizes[..<i].reduce(b.left + 24) { $0 + $1.width + 8 }
                    x = lead
                } else {
                    x -= s.width
                }
                f.buttons.insert(CGRect(x: x, y: footerTop + top + footerVariant.borderTop + (rowHeight - s.height) / 2,
                                        width: s.width, height: s.height), at: 0)
                x -= 8
            }
            y += footerVariant.borderTop + top + rowHeight + bottom
            f.footer = CGRect(x: b.left, y: footerTop, width: inner, height: y - footerTop)
        }
        f.height = y + b.bottom
        return f
    }

    public func height(forWidth width: CGFloat) -> CGFloat { frames(width: width).height }

    public override var intrinsicContentSize: NSSize {
        // Side sheets take the viewport's height, so only dialogs and top or bottom sheets have one.
        let fullHeight = kind == .sheet(.left) || kind == .sheet(.right)
        return NSSize(width: NSView.noIntrinsicMetric,
                      height: bounds.width > 0 && !fullHeight ? height(forWidth: bounds.width) : NSView.noIntrinsicMetric)
    }

    public override func layout() {
        super.layout()
        decoration.layout(boxSize: bounds.size)
        var f = frames(width: bounds.width)
        titleText.frame = f.title
        messageText.frame = f.message
        messageText.isHidden = !hasMessage
        // `DialogPanel` is a ScrollArea: when the host caps the dialog below its natural height, the panel scrolls
        // between the fixed header and footer.
        let overflow = f.height - bounds.height
        var buttons = f.buttons, footer = f.footer
        if overflow > 0.5, let first = f.panel.first, let last = f.panel.last {
            let top = first.minY - 4, bottom = last.maxY + (hasFooter && footerVariant == .bare ? 4 : 24)
            panelScroll.isHidden = false
            if panelScroll.superview == nil { addSubview(panelScroll, positioned: .below, relativeTo: closeButton) }
            panelScroll.frame = CGRect(x: borders.left, y: top, width: bounds.width - borders.left - borders.right, height: max(0, bottom - top - overflow))
            panelDocument.frame = CGRect(x: 0, y: 0, width: panelScroll.frame.width, height: bottom - top)
            for (view, frame) in zip(panelContent, f.panel) {
                if view.superview !== panelDocument { panelDocument.addSubview(view) }
                view.frame = frame.offsetBy(dx: -borders.left, dy: -top)
            }
            buttons = buttons.map { $0.offsetBy(dx: 0, dy: -overflow) }
            footer = footer.offsetBy(dx: 0, dy: -overflow)
        } else {
            panelScroll.isHidden = true
            for (view, frame) in zip(panelContent, f.panel) {
                if view.superview !== self { addSubview(view) }
                view.frame = frame
            }
        }
        zip(footerButtons, buttons).forEach { $0.frame = $1 }
        f.footer = footer
        footerLayer.isHidden = !hasFooter
        footerLayer.layout(boxSize: f.footer.size)
        footerLayer.frame.origin = CGPoint(x: f.footer.minX - footerLayer.outset, y: f.footer.minY - footerLayer.outset)
        closeButton.frame = NSRect(x: bounds.width - borders.right - 8 - 32 + (borders.right == 0 ? 0 : 1) - 1,
                                   y: 8, width: 32, height: 32)
    }

    public override func updateLayer() { restyle() }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        decoration.setNeedsDisplay()
        footerLayer.setNeedsDisplay()
    }

    private func restyle() {
        var box = BoxStyle()
        let rounded = !isSheet || isInset
        box.radius = rounded ? 18 : 0
        if isSheet {
            // `bg-popover not-dark:bg-clip-padding shadow-lg/5` with the 1px `::before` highlight.
            box.fill = Themed.color(\.popover)
            box.backgroundClip = .paddingInLight
            box.border = Themed.color(\.border)
            box.shadows = [BoxShadow(y: 10, blur: 15, spread: -3, color: Themed.black(0.05)),
                           BoxShadow(y: 4, blur: 6, spread: -4, color: Themed.black(0.05))]
            if !isInset {
                box.beforeShadows = [BoxShadow(y: 1, color: Themed.pick(light: Themed.black(0.04), dark: .clear)),
                                     BoxShadow(y: -1, color: Themed.pick(light: .clear, dark: Themed.white(0.06)))]
            }
        } else {
            // ponytail: `dialog-glass` is background at 80% blurred over the backdrop; drawn as solid --background,
            // which is what it composites to over T3's own backdrop tint. Real blur if content shows through visibly.
            box.fill = Themed.color(\.background)
            box.border = Themed.pick(light: Themed.color(\.contrastForeground, 0.1), dark: Themed.white(0.08))
            box.shadows = [
                BoxShadow(y: 1, color: Themed.pick(light: .clear, dark: Themed.white(0.04)), inset: true),
                BoxShadow(y: 24, blur: 64, spread: -24, color: Themed.pick(light: Themed.black(0.65), dark: .clear)),
                BoxShadow(y: 24, blur: 72, spread: -20, color: Themed.pick(light: .clear, dark: Themed.black(0.9))),
            ]
        }
        if isSheet && !isInset {
            let b = borders
            box.borderEdges = .init(top: b.top, left: b.left, bottom: b.bottom, right: b.right)
        }
        decoration.boxStyle = box

        var footer = BoxStyle()
        if footerVariant == .default {
            footer.fill = Themed.color(\.muted, 0.72)
            footer.border = Themed.color(\.contrastBorder)
            footer.radius = rounded ? 17 : 0
            footer.corners = .bottom
            footer.borderEdges = .init(top: 1)
        }
        footerLayer.boxStyle = footer
        titleText.color = Themed.color(\.contrastPopoverForeground)
        messageText.color = Themed.color(\.contrastMutedForeground)
    }
}

extension DialogView.FooterVariant {
    var borderTop: CGFloat { self == .default ? 1 : 0 }
}
