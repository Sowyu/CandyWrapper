import AppKit
import DesignSystem

/// Redesign's notices on the new-thread page: one quiet control at the trailing end of the project row, after Capy's
/// row of context then status (the user, 2026-11-26: the stacked notice and then four chips in a row both read as
/// clutter). One notice whose short title fits whole shows as an icon and that title, with Dismiss on hover; anything
/// else is one icon button, with a count when there are several. A click opens a popover with every notice in full:
/// title, description, its actions and Dismiss. Text is never cut, and only a warning or an error colors the icon.
public final class DitherNoticeControlView: ControlView {
    /// The banners the page would have shown, in order. Their actions and dismissals run through them.
    public private(set) var notices: [ComposerNoticeBannerView] = []
    private let surface = DitherPillSurface()
    private let fill = CALayer()
    private var icon = IconView(name: .info, size: 14)
    private let label = LabelView("", font: DSFont.ui(13))
    private let count = LabelView("", font: TL.tabular(11))
    private let dismiss = ButtonView(nil, icon: .x, variant: .ghostMuted, size: .iconXs)
    private var popup: OpenPopup?
    /// Whether the short title shows; set by `fit(room:)`.
    public private(set) var titled = false

    public override init(frame: NSRect) {
        super.init(frame: frame)
        scalesWhenPressed = false
        surface.quiet = true
        fill.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull()]
        fill.cornerRadius = DitherPill.radius
        layer?.masksToBounds = false
        addSubview(surface)
        layer?.addSublayer(fill)
        label.lineHeight = 16
        count.lineHeight = 14
        for v in [icon, label, count] as [NSView] { addSubview(v) }
        dismiss.setAccessibilityLabel("Dismiss")
        dismiss.setTooltip("Dismiss")
        dismiss.isHidden = true
        dismiss.action = { [weak self] in self?.dismissFirst() }
        addSubview(dismiss)
        setAccessibilityRole(.popUpButton)
        action = { [weak self] in self?.togglePopover() }
    }

    /// The notices to stand for. Their content decides the icon, its color and the title.
    public func update(_ notices: [ComposerNoticeBannerView]) {
        self.notices = notices
        guard let first = notices.first?.content else { return }
        let name: IconName = notices.count > 1 ? .info : first.icon
        if icon.name != name {
            icon.removeFromSuperview()
            icon = IconView(name: name, size: 14)
            addSubview(icon)
        }
        label.text = first.shortTitle ?? first.title
        count.text = notices.count > 1 ? "\(notices.count)" : ""
        setTooltip(first.title)
        setAccessibilityLabel(notices.count > 1 ? "\(notices.count) notices" : first.title)
        restyle()
        needsLayout = true
    }

    /// The control's width in `room`: the titled form when one notice's short title fits whole with `spare` left over,
    /// else the icon button.
    /// While the pointer is over the titled form it widens to the left for Dismiss; at rest it ends at the title.
    public func fit(room: CGFloat, spare: CGFloat = RedesignTokens.Space.xl) -> CGFloat {
        let resting = DitherPill.textX + ceil(label.textWidth) + DitherPill.pad
        let hovered = resting - DitherPill.pad + DitherPill.glyphGap + Self.dismissSize + DitherPill.pad / 2
        titled = notices.count == 1 && hovered + spare <= room
        return !titled ? iconWidth : showsDismiss ? hovered : resting
    }
    private var showsDismiss: Bool { state.hovered && notices.first?.content?.dismissible == true }

    private static let dismissSize: CGFloat = 20
    private var iconWidth: CGFloat {
        count.text.isEmpty ? DitherPill.height : DitherPill.pad + DitherPill.glyph + 4 + ceil(count.textWidth) + DitherPill.pad
    }

    public override func layout() {
        super.layout()
        let midY = bounds.height / 2
        surface.frame = bounds
        CATransaction.begin(); CATransaction.setDisableActions(true)
        DitherPill.placeFill(fill, in: bounds, quiet: true)
        CATransaction.commit()
        let iconX = titled || !count.text.isEmpty ? DitherPill.pad : (bounds.width - DitherPill.glyph) / 2
        icon.frame = NSRect(x: iconX, y: midY - 7, width: DitherPill.glyph, height: DitherPill.glyph)
        label.isHidden = !titled
        label.frame = NSRect(x: DitherPill.textX, y: midY - 8, width: ceil(label.textWidth) + 1, height: 16)
        count.isHidden = titled || count.text.isEmpty
        count.frame = NSRect(x: icon.frame.maxX + 4, y: midY - 7, width: ceil(count.textWidth) + 1, height: 14)
        dismiss.frame = NSRect(x: bounds.width - DitherPill.pad / 2 - Self.dismissSize, y: midY - Self.dismissSize / 2,
                               width: Self.dismissSize, height: Self.dismissSize)
        syncDismiss()
    }

    /// Dismiss shows on the titled form while the pointer is over it, for a notice that can be dismissed.
    private func syncDismiss() {
        dismiss.isHidden = !(titled && showsDismiss)
    }

    public override func stateDidChange(from old: State) {
        super.stateDidChange(from: old)
        syncDismiss()
        // The titled form makes room for Dismiss on hover; the page places it again.
        if titled && old.hovered != state.hovered { superview?.needsLayout = true }
        restyle()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    public override func updateLayer() {
        fill.backgroundColor = state.hoverOrPressed || popup != nil
            ? RedesignTokens.State.fill(state.activeOrPressed || popup != nil ? RedesignTokens.State.pressed : RedesignTokens.State.hover,
                                        dark: effectiveAppearance.isDark).cgColor : nil
    }

    private func restyle() {
        let lit = state.hoverOrPressed || popup != nil
        let text = lit ? Themed.color(\.foreground) : Themed.color(\.foreground, RedesignTokens.Text.quiet)
        label.color = text
        count.color = text
        icon.strokeColor = switch notices.first?.content?.variant {
        case .warning?: Themed.color(\.warningForeground)
        case .error?: Themed.color(\.destructiveForeground)
        default: text
        }
        needsDisplay = true
    }

    private func dismissFirst() {
        guard let notice = notices.first else { return }
        if let request = notice.onDismissRequest { request() } else { notice.onAction?(nil) }
    }

    // MARK: Popover

    private func togglePopover() {
        if let popup { window.map { PopupHost.host(for: $0).close(popup, returnFocus: false) }; return }
        let list = DitherNoticeListView(notices: notices)
        list.onDone = { [weak self] in
            guard let self, let popup = self.popup else { return }
            self.window.map { PopupHost.host(for: $0).close(popup, returnFocus: false) }
        }
        popup = PopoverView(content: list, padding: .compact, width: .md)
            .show(from: self, placement: PopupPlacement(side: .bottom, align: .end, sideOffset: 4, fallbackAxisSide: .none))
        popup?.onClose = { [weak self] in self?.popup = nil; self?.restyle() }
        restyle()
    }

    /// The open popover's notice titles, for tests.
    var popoverTitles: [String]? { ((popup?.content as? PopoverView)?.content as? DitherNoticeListView)?.titles }
}

/// The notices in full, one after another: icon and title, the description under it, then the actions and Dismiss.
final class DitherNoticeListView: DSView {
    var onDone: (() -> Void)?
    private struct Row { let icon: IconView; let title: TextBlockView; let detail: TextBlockView?; let buttons: [ButtonView] }
    private var rows: [Row] = []
    private(set) var titles: [String] = []
    private static let width: CGFloat = 320 - 2 * 12 - 2

    init(notices: [ComposerNoticeBannerView]) {
        super.init(frame: .zero)
        for notice in notices {
            guard let content = notice.content else { continue }
            let icon = IconView(name: content.icon, size: 14)
            icon.strokeColor = content.variant == .warning ? Themed.color(\.warningForeground)
                : content.variant == .error ? Themed.color(\.destructiveForeground) : Themed.color(\.mutedForeground)
            let title = TextBlockView(content.title, font: DSFont.ui(13, weight: .medium), lineHeight: 18, color: Themed.color(\.foreground))
            let detail = content.description.map { TextBlockView($0, font: DSFont.ui(12), lineHeight: 16, color: Themed.color(\.mutedForeground)) }
            var buttons: [ButtonView] = []
            for (i, name) in content.actions.enumerated() {
                let b = ButtonView(name, variant: .outline, size: .xs)
                b.isEnabled = !notice.disabledActions.contains(i)
                b.action = { [weak self, weak notice] in notice?.onAction?(i); self?.onDone?() }
                buttons.append(b)
            }
            if content.dismissible {
                let b = ButtonView(content.dismissLabel ?? "Dismiss", variant: .ghost, size: .xs)
                b.action = { [weak self, weak notice] in
                    if let request = notice?.onDismissRequest { request() } else { notice?.onAction?(nil) }
                    self?.onDone?()
                }
                buttons.append(b)
            }
            for v in [icon, title] as [NSView] { addSubview(v) }
            if let detail { addSubview(detail) }
            buttons.forEach(addSubview)
            rows.append(Row(icon: icon, title: title, detail: detail, buttons: buttons))
            titles.append(content.title)
        }
    }

    private static let gap = RedesignTokens.Space.m, textX: CGFloat = 14 + 8

    private func height(_ row: Row) -> CGFloat {
        let w = Self.width - Self.textX
        var h = row.title.height(forWidth: w)
        if let detail = row.detail { h += 2 + detail.height(forWidth: w) }
        if !row.buttons.isEmpty { h += RedesignTokens.Space.s + 24 }
        return h
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.width, height: rows.map(height).reduce(0, +) + Self.gap * CGFloat(max(0, rows.count - 1)))
    }

    override func layout() {
        super.layout()
        var y: CGFloat = 0
        let w = bounds.width - Self.textX
        for row in rows {
            row.icon.frame = NSRect(x: 0, y: y + 2, width: 14, height: 14)
            let th = row.title.height(forWidth: w)
            row.title.frame = NSRect(x: Self.textX, y: y, width: w, height: th)
            var bottom = y + th
            if let detail = row.detail {
                let dh = detail.height(forWidth: w)
                detail.frame = NSRect(x: Self.textX, y: bottom + 2, width: w, height: dh)
                bottom = detail.frame.maxY
            }
            var x = Self.textX
            for b in row.buttons {
                let bw = b.intrinsicContentSize.width
                b.frame = NSRect(x: x, y: bottom + RedesignTokens.Space.s, width: bw, height: 24)
                x += bw + RedesignTokens.Space.xs
            }
            y += height(row) + Self.gap
        }
    }
}
