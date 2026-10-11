import AppKit
import DesignSystem
import T3Protocol

/// A small text control on a detail row's second line (`THREAD_DETAILS_PANEL_META_ACTION_CLASS`):
/// `h-6 gap-1 rounded-md px-1.5 text-xs font-medium text-muted-foreground`, the panel hover fill. With
/// no text it is the `icon` part, a 24pt square (`THREAD_DETAILS_PANEL_ICON_ACTION_CLASS`).
public final class DetailsMetaControl: ControlView {
    public enum Tone: Sendable { case muted, primary, destructive }
    public var tone = Tone.muted { didSet { restyle() } }
    public var icon: IconDefinition? { didSet { rebuild() } }
    /// The icon on hover (the watch eye turns into eye-off).
    public var hoverIcon: IconDefinition? { didSet { rebuild() } }
    public var iconColor: NSColor? { didSet { restyle() } }
    /// An icon after the label (`ArrowUpRightIcon size-3` on Resolve and Fix).
    public var suffix: IconDefinition? { didSet { rebuild() } }
    public var text = "" { didSet { label.text = text; invalidateIntrinsicContentSize(); needsLayout = true } }
    /// The `icon` part: a 24pt square around the icon (the watch eye).
    public var isIconPart = false { didSet { invalidateIntrinsicContentSize(); needsLayout = true } }
    private let label = LabelView("", font: TL.tabular(12, .medium))
    private var iconView: IconView?
    private var hoverIconView: IconView?
    private var suffixView: IconView?
    private let fill = BoxDecorationLayer()
    private var tooltip: TooltipController?
    public var tooltipText: String? {
        didSet {
            if tooltip == nil, let tooltipText { tooltip = TooltipController.attach(to: self, text: tooltipText) }
            tooltip?.text = tooltipText ?? ""
        }
    }

    public init() {
        super.init(frame: .zero)
        fill.host = self
        layer?.addSublayer(fill)
        label.lineHeight = 16
        addSubview(label)
        setAccessibilityRole(.button)
        restyle()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private let iconSize: CGFloat = 14

    private func rebuild() {
        for v in [iconView, hoverIconView, suffixView] { v?.removeFromSuperview() }
        iconView = icon.map { IconView(definition: $0, size: iconSize) }
        hoverIconView = hoverIcon.map { IconView(definition: $0, size: iconSize) }
        suffixView = suffix.map { IconView(definition: $0, size: 12) }
        for v in [iconView, hoverIconView, suffixView] { v.map(addSubview) }
        invalidateIntrinsicContentSize()
        restyle()
        needsLayout = true
    }

    public override var intrinsicContentSize: NSSize {
        if isIconPart { return NSSize(width: 24, height: 24) }
        var w: CGFloat = 6 + (text.isEmpty ? 0 : ceil(label.textWidth)) + 6
        if icon != nil { w += 14 + (text.isEmpty ? 0 : 4) }
        if suffix != nil { w += 4 + 12 }
        return NSSize(width: w, height: 24)
    }

    public override func layout() {
        super.layout()
        fill.layout(boxSize: bounds.size)
        if isIconPart {
            let r = NSRect(x: (bounds.width - 14) / 2, y: (bounds.height - 14) / 2, width: 14, height: 14)
            iconView?.frame = r
            hoverIconView?.frame = r
            return
        }
        var x: CGFloat = 6
        if let iconView {
            iconView.frame = NSRect(x: x, y: 5, width: 14, height: 14)
            hoverIconView?.frame = iconView.frame
            x += 14 + 4
        }
        let w = ceil(label.textWidth)
        label.frame = NSRect(x: x, y: 4, width: w, height: 16)
        x += w + 4
        suffixView?.frame = NSRect(x: x, y: 6, width: 12, height: 12)
    }

    public override func stateDidChange(from old: State) { super.stateDidChange(from: old); restyle() }
    public override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); restyle() }

    private func restyle() {
        let color: NSColor = switch tone {
        case .muted: Themed.color(\.mutedForeground)
        case .primary: Themed.color(\.primary)
        case .destructive: Themed.color(\.destructive)
        }
        label.color = color
        let hovered = state.enabled && state.hoverOrPressed
        iconView?.strokeColor = iconColor ?? color
        hoverIconView?.strokeColor = iconColor ?? color
        suffixView?.strokeColor = color
        iconView?.isHidden = hoverIcon != nil && hovered
        hoverIconView?.isHidden = !hovered
        var box = BoxStyle()
        box.radius = 6
        box.fill = hovered ? detailsHoverFill() : nil
        fill.boxStyle = box
        alphaValue = state.enabled ? 1 : 0.64
    }
}

/// `ThreadDetailsPrRow` once the host answers (ThreadDetailsPrRow.tsx:434-476): the title gets the full
/// first row and a second line carries the number, the checks, the watch eye and one action, aligned
/// with the title text (`-mt-1 h-6 ps-9 pe-1 gap-0.5`); `pb-2` keeps stacked pull requests apart.
public final class ThreadDetailsPrRowView: DSView {
    public static let height: CGFloat = 32 - 4 + 24 + 8
    public let open = DetailsRowControl(kind: .row)
    private let number = LabelView("", font: TL.tabular(12))
    public let checks = DetailsMetaControl()
    public let watch = DetailsMetaControl()
    public let action = DetailsMetaControl()

    public init() {
        super.init(frame: .zero)
        number.lineHeight = 16
        watch.isIconPart = true
        watch.icon = IconName.eye.definition
        watch.hoverIcon = IconName.eyeOff.definition
        watch.tooltipText = "Watching: the agent wakes when checks finish, someone comments, or the branch conflicts. Click to stop."
        [open, number, checks, watch, action].forEach(addSubview)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// The second line's `#n`.
    public var numberText = "" { didSet { number.text = numberText; needsLayout = true } }

    public override func layout() {
        super.layout()
        open.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 32)
        let y: CGFloat = 32 - 4
        var x: CGFloat = 36
        let nw = ceil(number.textWidth)
        number.frame = NSRect(x: x, y: y + 4, width: nw, height: 16)
        x += nw + 4 + 2
        for control in [checks, watch] where !control.isHidden {
            let w = control.intrinsicContentSize.width
            control.frame = NSRect(x: x, y: y, width: w, height: 24)
            x += w + 2
        }
        if !action.isHidden {
            let w = action.intrinsicContentSize.width
            action.frame = NSRect(x: bounds.width - 4 - w, y: y, width: w, height: 24)
        }
    }

    public override func updateLayer() {
        number.color = Themed.color(\.mutedForeground)
    }
}
