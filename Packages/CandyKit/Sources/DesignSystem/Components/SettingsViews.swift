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
        didSet {
            oldValue?.removeFromSuperview(); control.map(addSubview)
            controlWidth = control?.frame.width ?? 0
            invalidateIntrinsicContentSize(); needsLayout = true
        }
    }
    /// A control without an intrinsic width keeps the width it came with; the stacked layout stretches its frame.
    private var controlWidth: CGFloat = 0
    /// `status`: a line under the description (`pt-0.5 text-xs text-muted-foreground`), destructive for errors.
    public var status: String? { didSet { statusText.text = status ?? ""; statusText.isHidden = status == nil; invalidateIntrinsicContentSize(); needsLayout = true } }
    /// Mixed inline status content can have a taller baseline-aligned line box.
    public var statusLineHeight: CGFloat = 16 { didSet { statusText.lineHeight = statusLineHeight; invalidateIntrinsicContentSize(); needsLayout = true } }
    public var statusIsError = false {
        didSet {
            statusText.color = statusIsError ? Themed.color(\.destructive) : Themed.color(\.contrastMutedForeground)
            statusLinkView?.color = statusText.color
        }
    }
    /// An underlined link after the status text (`<a className="underline underline-offset-2">`), such as T3 Connect's
    /// "More info". It follows the last line, or takes its own line when it doesn't fit.
    public var statusLink: (title: String, action: @MainActor @Sendable () -> Void)? {
        didSet {
            statusLinkView?.removeFromSuperview()
            statusLinkView = statusLink.map { link in
                let v = StatusLinkView(link.title, color: statusText.color)
                v.action = link.action
                addSubview(v)
                return v
            }
            invalidateIntrinsicContentSize(); needsLayout = true
        }
    }
    private var statusLinkView: StatusLinkView?
    /// A link inside the description (`<Link className="underline underline-offset-2">`), such as the Beta page's
    /// "Connections": `title` is a run of `detail` that gets underlined and opens on click.
    public var detailLink: (title: String, action: @MainActor () -> Void)? { didSet { needsLayout = true } }
    private var detailLinkViews: [DetailLinkView] = []
    /// A description in `text-destructive`, such as a failed cleanup entry.
    public var detailIsError = false { didSet { detailText.color = detailIsError ? Themed.color(\.destructive) : Themed.color(\.contrastMutedForeground, 0.8); applyDither() } }
    /// `aria-disabled`: opacity .64 (and muted text, which the dimmed foreground approximates).
    public var isDisabled = false { didSet { alphaValue = isDisabled ? 0.64 : 1 } }
    /// The 1px `border-t border-border/50` a divided group gives every row after the first.
    var topBorder = false { didSet { needsDisplay = true; invalidateIntrinsicContentSize() } }
    /// 20pt slots after the title (`flex min-h-5 items-center gap-1.5`): the inheritance indicator and
    /// the reset arrow. T3 always keeps the reset slot, so pass an empty view for an empty slot.
    public var accessories: [NSView] = [] {
        didSet { oldValue.forEach { $0.removeFromSuperview() }; accessories.forEach(addSubview); needsLayout = true }
    }
    /// A view in place of the description text, laid out at its frame height (the keybinding `When` line),
    /// or at the height it asks for at the description's width when it is a `SettingsGroupRow`
    /// (the storage cleanup result's grid).
    public var detailView: NSView? {
        didSet { oldValue?.removeFromSuperview(); detailView.map(addSubview); invalidateIntrinsicContentSize(); needsLayout = true }
    }
    /// A view under the row (`children`, `pt-3 pb-1`), such as an inline editor.
    public var footer: (NSView & SettingsGroupRow)? {
        didSet { oldValue?.removeFromSuperview(); footer.map(addSubview); invalidateIntrinsicContentSize(); needsLayout = true }
    }
    /// The inert control of a server row nobody can save (`inertControl`): dimmed to .5 with this tooltip.
    public var inertReason: String? { didSet { applyInert() } }
    /// `bg-muted/15` (the new keybinding row).
    public var fill: NSColor? { didSet { needsDisplay = true } }
    /// A 14pt glyph before the title (`inline-flex items-center gap-2`), such as the Archive page's spinner.
    public var titleIcon: NSView? { didSet { oldValue?.removeFromSuperview(); titleIcon.map(addSubview); needsLayout = true } }
    private let inertCover = InertCoverView()

    private let titleLabel = LabelView()
    private let detailText = TextBlockView()
    private let statusText = TextBlockView()
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
        statusText.font = DSFont.ui(12)
        statusText.lineHeight = 16
        statusText.color = Themed.color(\.contrastMutedForeground)
        statusText.isHidden = true
        addSubview(titleLabel)
        addSubview(detailText)
        addSubview(statusText)
        control.map(addSubview)
        controlWidth = control?.frame.width ?? 0
        layer?.addSublayer(border)
        inertCover.isHidden = true
        addSubview(inertCover)
        applyDither()
    }

    public override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyDither() }

    /// Dither (after Capy's settings rows): a 13pt regular title in the foreground over a 12pt description in
    /// `--muted-foreground-1` (#aaaaab in dark), same line heights.
    private func applyDither() {
        let dither = ThemeRuntime.isDither(dark: effectiveAppearance.isDark)
        titleLabel.font = dither ? DSFont.ui(13) : DSFont.ui(14, weight: .medium)
        titleLabel.color = Themed.color(dither ? \.foreground : \.contrastForeground)
        detailText.balanced = !DesignGeometry.usesClassic(self)
        if !detailIsError {
            detailText.color = dither ? Themed.color(\.mutedForeground)
                : Themed.color(\.contrastMutedForeground, DesignGeometry.usesClassic(self) ? 0.8 : 1)
        }
        // A select sizes itself to its value under Dither, so the control column changes with the theme.
        invalidateIntrinsicContentSize(); needsLayout = true
    }

    private func applyInert() {
        control?.alphaValue = inertReason == nil ? 1 : 0.5
        inertCover.isHidden = inertReason == nil
        inertCover.toolTip = inertReason
        if inertReason != nil { addSubview(inertCover, positioned: .above, relativeTo: nil) }
        needsLayout = true
    }

    /// Takes the clicks of an inert control and shows why.
    final class InertCoverView: NSView {
        override func mouseDown(with event: NSEvent) {}
        override func mouseUp(with event: NSEvent) {}
    }

    static let paddingX: CGFloat = 16, paddingY: CGFloat = 12

    private struct Frames { var title, detail, control: NSRect; var status = NSRect.zero; var height: CGFloat }

    private func frames(width: CGFloat) -> Frames {
        let detailLimit: CGFloat = DesignGeometry.usesClassic(self) ? 576 : 672
        let top = Self.paddingY + (topBorder ? 1 : 0)
        let inner = max(0, width - 2 * Self.paddingX)
        let controlSize = control.map { c -> NSSize in
            let s = c.intrinsicContentSize
            return NSSize(width: s.width == NSView.noIntrinsicMetric ? (controlWidth > 0 ? controlWidth : c.frame.width) : s.width,
                          height: s.height == NSView.noIntrinsicMetric ? c.frame.height : s.height)
        } ?? .zero
        func detailHeight(_ w: CGFloat) -> CGFloat {
            if let row = detailView as? SettingsGroupRow { return row.height(forWidth: min(detailLimit, w)) }
            if let detailView { return detailView.frame.height }
            return detail == nil ? 0 : detailText.height(forWidth: min(detailLimit, w))
        }
        let hasDetail = detail != nil || detailView != nil
        func statusHeight(_ w: CGFloat) -> CGFloat {
            guard status != nil else { return 0 }
            return statusText.height(forWidth: w) + (statusLinkPlacement(w)?.ownLine == true ? 16 : 0)
        }
        func textHeight(_ w: CGFloat) -> CGFloat {
            20 + (hasDetail ? 4 + detailHeight(w) : 0) + (status == nil ? 0 : 4 + 2 + statusHeight(w))
        }
        if width >= 512 {
            // grid-cols-[minmax(0,1fr)_minmax(10rem,auto)] gap-8 items-center
            let controlColumn = control == nil ? 0 : max(160, controlSize.width)
            let textWidth = max(0, inner - controlColumn - (control == nil ? 0 : 32))
            let th = textHeight(textWidth)
            let rowHeight = max(th, controlSize.height)
            let textY = top + (rowHeight - th) / 2
            return Frames(title: NSRect(x: Self.paddingX, y: textY, width: textWidth, height: 20),
                          detail: NSRect(x: Self.paddingX, y: textY + 24, width: min(detailLimit, textWidth), height: detailHeight(textWidth)),
                          control: NSRect(x: width - Self.paddingX - controlSize.width, y: top + (rowHeight - controlSize.height) / 2,
                                          width: controlSize.width, height: controlSize.height),
                          status: NSRect(x: Self.paddingX, y: textY + th - statusHeight(textWidth), width: textWidth, height: statusHeight(textWidth)),
                          height: top + rowHeight + footerHeight(width))
        }
        let th = textHeight(inner)
        let controlY = top + th + 12
        return Frames(title: NSRect(x: Self.paddingX, y: top, width: inner, height: 20),
                      detail: NSRect(x: Self.paddingX, y: top + 24, width: min(detailLimit, inner), height: detailHeight(inner)),
                      control: NSRect(x: Self.paddingX, y: controlY, width: inner, height: controlSize.height),
                      status: NSRect(x: Self.paddingX, y: top + th - statusHeight(inner), width: inner, height: statusHeight(inner)),
                      height: (control == nil ? top + th : controlY + controlSize.height) + footerHeight(width))
    }

    /// Where the status link goes: after the last line plus a space, or on a line of its own.
    private func statusLinkPlacement(_ width: CGFloat) -> (x: CGFloat, line: Int, ownLine: Bool)? {
        guard let link = statusLinkView else { return nil }
        let lines = statusText.layout(forWidth: width)
        let last = ceil(lines.widths.last ?? 0)
        let fits = last + 4 + link.intrinsicContentSize.width <= width
        return fits ? (last + 4, max(0, lines.lines.count - 1), false) : (0, lines.lines.count, true)
    }

    /// `pt-3 pb-1` with children, else `py-3`.
    private func footerHeight(_ width: CGFloat) -> CGFloat {
        guard let footer else { return Self.paddingY }
        return 12 + footer.height(forWidth: width - 2 * Self.paddingX) + 4
    }

    public func height(forWidth width: CGFloat) -> CGFloat { frames(width: width).height }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: bounds.width > 0 ? height(forWidth: bounds.width) : NSView.noIntrinsicMetric)
    }

    public override func layout() {
        super.layout()
        let f = frames(width: bounds.width)
        // 20pt slots, or a view's own size (the keybinding source badge, `gap-2` after the title).
        func size(_ a: NSView) -> NSSize {
            let s = a.intrinsicContentSize
            return s.width == NSView.noIntrinsicMetric ? NSSize(width: 20, height: 20) : s
        }
        let slots = accessories.reduce(0) { $0 + size($1).width + 6 }
        let iconInset: CGFloat = titleIcon == nil ? 0 : 14 + 8
        titleIcon?.frame = NSRect(x: f.title.minX, y: f.title.minY + 3, width: 14, height: 14)
        let titleWidth = min(ceil(titleLabel.textWidth) + 1, max(0, f.title.width - slots - iconInset))
        titleLabel.frame = NSRect(x: f.title.minX + iconInset, y: f.title.minY, width: titleWidth, height: 20)
        var ax = f.title.minX + iconInset + titleWidth + 6
        for a in accessories {
            let s = size(a)
            if s.width > 20 { ax += 2 }
            a.frame = NSRect(x: ax, y: f.title.minY + (20 - s.height) / 2, width: s.width, height: s.height)
            ax += s.width + 6
        }
        detailText.frame = f.detail
        layoutDetailLink()
        if let row = detailView as? SettingsGroupRow {
            row.frame = f.detail
        } else if let detailView {
            detailView.frame = NSRect(x: f.detail.minX, y: f.detail.minY, width: f.title.width, height: detailView.frame.height)
        }
        if let footer {
            let fh = footer.height(forWidth: bounds.width - 2 * Self.paddingX)
            footer.frame = NSRect(x: Self.paddingX, y: bounds.height - 4 - fh, width: bounds.width - 2 * Self.paddingX, height: fh)
        }
        inertCover.frame = f.control
        statusText.frame = f.status
        if let link = statusLinkView, let p = statusLinkPlacement(f.status.width) {
            link.isHidden = status == nil
            link.frame = NSRect(x: f.status.minX + p.x, y: f.status.minY + CGFloat(p.line) * 16, width: link.intrinsicContentSize.width, height: 16)
        }
        control?.frame = f.control
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        border.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 1)
        border.isHidden = !topBorder
        CATransaction.commit()
    }

    public override func updateLayer() {
        border.backgroundColor = SettingsGroupView.dividerColor(dither: ThemeRuntime.isDither(dark: effectiveAppearance.isDark)).cgColor(in: self)
        layer?.backgroundColor = fill?.cgColor(in: self)
    }
}

/// A view that sizes itself to a width, so a settings card can stack it.
@MainActor public protocol SettingsGroupRow: NSView {
    func height(forWidth width: CGFloat) -> CGFloat
}

extension SettingsRowView: SettingsGroupRow {}

/// `SettingsGroup`: the canonical card. 14px radius, border/60, card/40, `shadow-xs/5`, rows divided by border/50.
/// Rows are `SettingsRowView`s or any other `SettingsGroupRow` (T3 puts environment rows and empty states
/// straight in the group); `[&>*+*]:border-t` gives every row after the first a 1px top border.
public final class SettingsGroupView: BoxView {
    public enum Variant: Sendable { case grouped, plain, embedded }
    public var rows: [any SettingsGroupRow] {
        didSet { oldValue.forEach { $0.removeFromSuperview() }; rows.forEach { addSubview($0) }; restyle(); needsLayout = true }
    }
    public var variant: Variant { didSet { restyle(); needsLayout = true } }
    private var dividers: [CALayer] = []

    public init(rows: [any SettingsGroupRow], variant: Variant = .grouped) {
        self.rows = rows
        self.variant = variant
        super.init(frame: .zero)
        rows.forEach { addSubview($0) }
        restyle()
    }

    private func restyle() {
        var box = BoxStyle()
        if variant == .grouped, ThemeRuntime.isDither(dark: effectiveAppearance.isDark) {
            // Dither (after Capy's settings cards): a translucent fill a step lighter than the page, so the art
            // under the page faintly shows through, ringed by a faint light 1pt rim. Measured on Capy in dark:
            // the card reads #222 over art averaging #1c1d1e, the rim #2b2a2b.
            box.radius = DitherChrome.cardRadius
            box.border = Themed.color(light: \.foreground, 0.08, dark: \.foreground, 0.06)
            box.fill = Themed.pick(light: Themed.color(\.card, 0.82), dark: Self.ditherDarkCard)
        } else if variant == .grouped {
            box.radius = DesignGeometry.radius(14, in: self)
            box.border = Themed.color(\.contrastBorder, 0.6)
            box.fill = Themed.color(\.card, 0.4)
            box.shadows = [BoxShadow(y: 1, blur: 2, color: Themed.black(0.05))]
        }
        boxStyle = box
        for row in rows { (row as? SettingsRowView)?.topBorder = false }
        let count = variant != .plain ? max(0, rows.count - 1) : 0
        while dividers.count < count {
            let l = CALayer()
            l.actions = ["position": NSNull(), "bounds": NSNull(), "backgroundColor": NSNull(), "hidden": NSNull()]
            layer?.addSublayer(l)
            dividers.append(l)
        }
        while dividers.count > count { dividers.removeLast().removeFromSuperlayer() }
        needsDisplay = true
    }

    public override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); restyle(); needsLayout = true }

    /// Capy's settings card in dark: #222 where its art averages #1c1d1e, so about #222223 at 86%.
    static let ditherDarkCard = NSColor(srgbRed: 0x22 / 255, green: 0x22 / 255, blue: 0x23 / 255, alpha: 0.86)

    /// The rows' dividers: T3's border/50, or under Dither Capy's hairline (`--border-1`, black 11% in light where
    /// Capy rings its cards with that shadow).
    static func dividerColor(dither: Bool) -> NSColor {
        dither ? Themed.color(light: \.foreground, 0.11, dark: \.foreground, 0.08) : Themed.color(\.contrastBorder, 0.5)
    }

    private var inset: CGFloat { variant == .plain ? 0 : 1 }
    private var gap: CGFloat { variant == .plain ? 4 : 1 }  // `space-y-1`, or the 1px top border

    /// Redesign keeps some of a card's rows in a section (`DitherSettingsSectionView`); rows this refuses stay hidden.
    public var rowFilter: ((NSView) -> Bool)? { didSet { needsLayout = true } }

    /// Rows that render; a hidden row leaves the card like T3's conditional rows.
    private var shown: [any SettingsGroupRow] { rows.filter { !$0.isHidden && rowFilter?($0) != false } }

    public func height(forWidth width: CGFloat) -> CGFloat {
        let shown = shown
        return shown.reduce(0) { $0 + $1.height(forWidth: width - 2 * inset) } + gap * CGFloat(max(0, shown.count - 1)) + 2 * inset
    }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: bounds.width > 0 ? height(forWidth: bounds.width) : NSView.noIntrinsicMetric)
    }

    public override func layout() {
        super.layout()
        if let rowFilter { for row in rows where !rowFilter(row) { row.isHidden = true } }
        var y = inset
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Dither's dividers are a 0.5pt hairline centred in T3's 1pt gap.
        let hairline = ThemeRuntime.isDither(dark: effectiveAppearance.isDark)
        for d in dividers { d.isHidden = true }
        for (i, row) in shown.enumerated() {
            if i > 0 {
                if variant != .plain {
                    dividers[i - 1].frame = hairline ? CGRect(x: inset, y: y + 0.25, width: bounds.width - 2 * inset, height: 0.5)
                        : CGRect(x: inset, y: y, width: bounds.width - 2 * inset, height: 1)
                    dividers[i - 1].isHidden = false
                }
                y += gap
            }
            let h = row.height(forWidth: bounds.width - 2 * inset)
            row.frame = NSRect(x: inset, y: y, width: bounds.width - 2 * inset, height: h)
            y += h
        }
        CATransaction.commit()
    }

    public override func updateLayer() {
        super.updateLayer()
        let color = Self.dividerColor(dither: ThemeRuntime.isDither(dark: effectiveAppearance.isDark)).cgColor(in: self)
        for d in dividers { d.backgroundColor = color }
    }
}

/// `SettingsSection`: a 28px header (14px regular, foreground at 70%) 10px above its card.
public final class SettingsSectionView: DSView {
    public let group: SettingsGroupView
    public var title: String { didSet { titleLabel.text = title } }
    /// The header's trailing action slot (`min-h-7 min-w-7`).
    public var headerAction: NSView? { didSet { oldValue?.removeFromSuperview(); headerAction.map(addSubview); needsLayout = true } }
    /// The `icon` before the title (`gap-2`), such as the machine glyph of "This machine".
    public var icon: NSView? { didSet { oldValue?.removeFromSuperview(); icon.map(addSubview); needsLayout = true } }
    private let titleLabel = LabelView()

    public init(title: String, rows: [any SettingsGroupRow], variant: SettingsGroupView.Variant = .grouped) {
        self.title = title
        group = SettingsGroupView(rows: rows, variant: variant)
        super.init(frame: .zero)
        titleLabel.text = title
        titleLabel.font = DSFont.ui(14)
        titleLabel.lineHeight = 20
        titleLabel.color = Themed.color(\.contrastForeground, 0.7)
        addSubview(titleLabel)
        addSubview(group)
        applyDither()
    }

    public override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyDither() }

    /// Dither (after Capy's section labels): 15pt regular in the foreground color.
    private func applyDither() {
        let dither = ThemeRuntime.isDither(dark: effectiveAppearance.isDark)
        let classic = DesignGeometry.usesClassic(self)
        titleLabel.font = dither ? DSFont.ui(15) : classic ? DSFont.ui(14) : DSFont.ui(16, weight: .semibold)
        titleLabel.lineHeight = classic ? 20 : 24
        titleLabel.color = Themed.color(\.contrastForeground, dither || !classic ? 1 : 0.7)
        needsLayout = true
    }

    public func height(forWidth width: CGFloat) -> CGFloat { 28 + 10 + group.height(forWidth: width) }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: bounds.width > 0 ? height(forWidth: bounds.width) : NSView.noIntrinsicMetric)
    }

    public override func layout() {
        super.layout()
        let titleX: CGFloat = icon == nil ? 16 : 16 + 16 + 8
        icon?.frame = NSRect(x: 16, y: 6, width: 16, height: 16)
        let line: CGFloat = DesignGeometry.usesClassic(self) ? 20 : 24
        titleLabel.frame = NSRect(x: titleX, y: (28 - line) / 2, width: max(0, bounds.width - titleX - 16 - 28 - 16), height: line)
        if let action = headerAction {
            let s = action.intrinsicContentSize
            action.frame = NSRect(x: bounds.width - 16 - s.width, y: (28 - s.height) / 2, width: s.width, height: s.height)
        }
        group.frame = NSRect(x: 0, y: 38, width: bounds.width, height: group.height(forWidth: bounds.width))
    }
}

extension SettingsSectionView: SettingsGroupRow {}
extension SettingsGroupView: SettingsGroupRow {}

extension SettingsRowView {
    /// One hit area per line the link's run covers, each drawing the underline under its piece.
    fileprivate func layoutDetailLink() {
        var pieces: [(rect: CGRect, baseline: CGFloat)] = []
        if let link = detailLink, let detail, !detailText.isHidden {
            let range = (detail as NSString).range(of: link.title)
            if range.location != NSNotFound { pieces = detailText.runRects(range, width: detailText.bounds.width) }
        }
        while detailLinkViews.count > pieces.count { detailLinkViews.removeLast().removeFromSuperview() }
        while detailLinkViews.count < pieces.count {
            let v = DetailLinkView()
            addSubview(v)
            detailLinkViews.append(v)
        }
        for (v, piece) in zip(detailLinkViews, pieces) {
            v.frame = piece.rect.offsetBy(dx: detailText.frame.minX, dy: detailText.frame.minY)
            v.baseline = piece.baseline - piece.rect.minY
            v.color = detailText.color
            v.action = detailLink?.action
            v.setAccessibilityLabel(detailLink?.title)
            v.needsDisplay = true
        }
    }
}

/// A piece of a description link: draws `underline-offset-2` under the text the row already drew, and takes the click.
final class DetailLinkView: ControlView {
    var baseline: CGFloat = 0
    var color: NSColor = .clear
    override init(frame: NSRect) {
        super.init(frame: frame)
        scalesWhenPressed = false
        setAccessibilityRole(.link)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(color.cgColor(in: self))
        ctx.fill(CGRect(x: 0, y: baseline + 2, width: bounds.width, height: 1))
    }
}

/// The status line's link: 12pt underlined text in the status color that opens on click.
final class StatusLinkView: ControlView {
    private let label: LabelView
    var color: NSColor { get { label.color } set { label.color = newValue } }

    init(_ title: String, color: NSColor) {
        label = LabelView(title, font: DSFont.ui(12), color: color)
        super.init(frame: .zero)
        scalesWhenPressed = false
        label.lineHeight = 16
        label.isUnderlined = true
        addSubview(label)
        setAccessibilityRole(.link)
        setAccessibilityLabel(title)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: ceil(label.textWidth) + 1, height: 16) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func layout() { super.layout(); label.frame = bounds }
}
