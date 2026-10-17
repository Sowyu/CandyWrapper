import AppKit

/// T3's `SidebarMenuButton` and `SidebarMenuSubButton` (`components/ui/sidebar.tsx:662-794`), with the
/// `[data-app-sidebar]` colors. Spec: docs/research/recovered/ui-components-b.md 19.9-19.10.
/// T3 has no badge or action part; the app composes them, so `accessory` takes any trailing view
/// (BadgeView, KbdView, an icon ButtonView) and `statusDot` the row's status color (sidebar-derived-state.md).
public final class SidebarMenuButtonView: ControlView {
    public enum Size: String, CaseIterable, Sendable {
        case `default`, sm, lg, icon
        /// Height, radius, inline padding, font px, line-height.
        var metrics: (height: CGFloat, radius: CGFloat, padding: CGFloat, font: CGFloat, line: CGFloat) {
            switch self {
            case .default: (32, 8, 10, 14, 20)
            case .sm: (28, 10, 8, 12, 16)
            case .lg: (48, 10, 8, 14, 20)
            case .icon: (32, 8, 0, 14, 20)
            }
        }
    }

    public enum Variant: String, CaseIterable, Sendable { case `default`, outline }

    /// `menu` is SidebarMenuButton; `sub` is SidebarMenuSubButton (always sidebar-foreground, regular weight).
    public enum Kind: Sendable { case menu, sub(small: Bool) }

    public var title: String { didSet { label.text = title; needsLayout = true } }
    public var icon: IconName? { didSet { updateIcon() } }
    /// An icon outside the generated set (T3's `createLucideIcon` glyphs). Wins over `icon`.
    public var iconDefinition: IconDefinition? { didSet { updateIcon() } }
    public var size: Size = .default { didSet { restyle(); invalidateIntrinsicContentSize() } }
    public var variant: Variant = .default { didSet { restyle() } }
    /// A clear compose glyph in CandyWrapper's Glass sidebar header.
    public var isHeaderAction = false { didSet { restyle() } }
    public let kind: Kind
    /// `data-active=true`: the selected row.
    public var isActive = false { didSet { restyle(); setAccessibilitySelected(isActive) } } // `data-active`, read as selected
    public var accessory: NSView? {
        didSet { oldValue?.removeFromSuperview(); if let accessory { addSubview(accessory) }; needsLayout = true }
    }
    /// A 6px dot before the title (unread, running). Nil hides it.
    // ponytail: dot geometry is a placeholder until the thread-row milestone copies Sidebar.tsx's indicator classes
    public var statusDot: NSColor? { didSet { needsDisplay = true; needsLayout = true } }

    private let decoration = BoxDecorationLayer()
    private let dot = CALayer()
    private let label = LabelView()
    private var iconView: IconView?

    public init(_ title: String, icon: IconName? = nil, size: Size = .default, variant: Variant = .default,
                kind: Kind = .menu, active: Bool = false) {
        self.title = title
        self.kind = kind
        super.init(frame: .zero)
        decoration.host = self
        layer?.addSublayer(decoration)
        layer?.masksToBounds = false
        dot.actions = ["backgroundColor": NSNull(), "frame": NSNull(), "position": NSNull(), "bounds": NSNull()]
        layer?.addSublayer(dot)
        scalesWhenPressed = false // no `active:scale` on sidebar rows
        label.text = title
        addSubview(label)
        self.size = size
        self.variant = variant
        self.isActive = active
        self.icon = icon
        updateIcon()
        restyle()
        setAccessibilityLabel(title)
        setAccessibilitySelected(active)
    }

    var isSub: Bool { if case .sub = kind { return true } else { return false } }

    public override var intrinsicContentSize: NSSize {
        if isSub { return NSSize(width: NSView.noIntrinsicMetric, height: 28) }
        let m = size.metrics
        return size == .icon ? NSSize(width: 32, height: 32) : NSSize(width: NSView.noIntrinsicMetric, height: m.height)
    }

    // MARK: Layout

    public override func layout() {
        super.layout()
        decoration.layout(boxSize: bounds.size)
        let padding: CGFloat = isSub ? 8 : size.metrics.padding
        let line: CGFloat = isSub ? (font.pointSize == 12 ? 16 : 20) : size.metrics.line
        if size == .icon && !isSub {
            iconView?.frame = NSRect(x: (bounds.width - 16) / 2, y: (bounds.height - 16) / 2, width: 16, height: 16)
            label.isHidden = true
            return
        }
        label.isHidden = false
        var x = padding
        let gap: CGFloat = 8
        if statusDot != nil {
            dot.frame = CGRect(x: x, y: (bounds.height - 6) / 2, width: 6, height: 6)
            x += 6 + gap
        }
        if let iconView {
            iconView.frame = NSRect(x: x, y: (bounds.height - 16) / 2, width: 16, height: 16)
            x += 16 + gap
        }
        var right = bounds.width - padding
        if let accessory {
            let s = accessory.intrinsicContentSize
            accessory.frame = NSRect(x: right - s.width, y: (bounds.height - s.height) / 2, width: s.width, height: s.height)
            right -= s.width + gap
        }
        label.frame = NSRect(x: x, y: (bounds.height - line) / 2, width: max(0, right - x), height: line)
    }

    // MARK: Style

    private var font: NSFont { label.font }

    public override func stateDidChange(from old: State) {
        super.stateDidChange(from: old)
        restyle()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        decoration.setNeedsDisplay()
        restyle()
    }

    public override func updateLayer() {
        dot.backgroundColor = statusDot?.cgColor(in: self)
        dot.cornerRadius = 3
        dot.isHidden = statusDot == nil
    }

    private func restyle() {
        var look = SidebarRowStyles.look(kind: kind, size: size, variant: variant, active: isActive, state: state)
        if isHeaderAction, WindowGlass.isActive(for: self) {
            look.box.radius = 10
            look.box.border = nil
            look.icon = Themed.color(\.sidebarForeground, sidebar: true)
        }
        decoration.boxStyle = look.box
        label.color = look.text
        label.font = look.font
        label.lineHeight = look.line
        iconView?.strokeColor = look.icon
        needsLayout = true
    }

    private func updateIcon() {
        iconView?.removeFromSuperview()
        iconView = iconDefinition.map { IconView(definition: $0) } ?? icon.map { IconView(name: $0) }
        if let iconView { addSubview(iconView) }
        restyle()
    }
}

@MainActor
enum SidebarRowStyles {
    struct Look { var box: BoxStyle; var text: NSColor; var icon: NSColor; var font: NSFont; var line: CGFloat }

    static func look(kind: SidebarMenuButtonView.Kind, size: SidebarMenuButtonView.Size, variant: SidebarMenuButtonView.Variant,
                     active: Bool, state: ControlView.State) -> Look {
        let fg = Themed.color(\.contrastSidebarForeground, sidebar: true)
        var box = BoxStyle()
        box.border = nil
        let hoverFill = Themed.color(\.sidebarRowHover, sidebar: true)
        let activeFill = Themed.color(\.sidebarRowActive, sidebar: true)
        let selectedFill = Themed.color(\.sidebarRowSelected, sidebar: true)

        if case .sub(let small) = kind {
            box.radius = 10
            // Source order: hover, then active, then data-active (selected) last.
            if state.hovered { box.fill = hoverFill }
            if state.active { box.fill = activeFill }
            if active { box.fill = selectedFill }
            if state.focusVisible { box.shadows = [BoxShadow(spread: 2, color: Themed.color(\.ring))] }
            return Look(box: box, text: fg, icon: Themed.color(\.contrastSidebarMutedForeground, sidebar: true),
                        font: DSFont.ui(small ? 12 : 14), line: small ? 16 : 20)
        }

        let m = size.metrics
        box.radius = m.radius
        var text = Themed.color(\.contrastSidebarMutedForeground, 0.8, sidebar: true)
        var icon = Themed.color(\.sidebarIconColor, sidebar: true)
        var ringColor = Themed.color(\.ring)
        var weight: NSFont.Weight = .medium
        if variant == .outline {
            // The outline variant sets no font-medium or muted color, so the row inherits sidebar-foreground at 400.
            text = fg
            weight = active ? .medium : .regular
            box.fill = Themed.color(\.sidebarControlSurface, sidebar: true)
            box.shadows = [BoxShadow(spread: 1, color: Themed.color(\.sidebarBorder, sidebar: true))]
            ringColor = Themed.color(\.sidebarBorder, sidebar: true)
        }
        if state.hovered { box.fill = hoverFill; text = fg; icon = fg }
        if state.active { box.fill = activeFill; text = fg; icon = fg }
        if active { box.fill = selectedFill; text = fg; icon = fg }
        if state.focusVisible {
            // `ring-2` replaces the outline variant's `ring-1` (same --tw-ring-shadow slot).
            box.shadows = [BoxShadow(spread: 2, color: ringColor)]
        }
        return Look(box: box, text: text, icon: icon, font: DSFont.ui(m.font, weight: weight), line: m.line)
    }
}

/// `SidebarGroup` > `SidebarMenu`: 8px padding (`--sidebar-content-inset`) and rows 4px apart.
/// A row followed by a `SidebarMenuSubView` shows it below, indented.
public final class SidebarMenuView: DSView {
    public let rows: [NSView]
    public var padding: CGFloat = 8 { didSet { needsLayout = true } }

    public init(_ rows: [NSView]) {
        self.rows = rows
        super.init(frame: .zero)
        rows.forEach(addSubview)
        setAccessibilityRole(.list)
    }

    public var contentHeight: CGFloat {
        rows.reduce(0) { $0 + height(of: $1) } + CGFloat(max(0, rows.count - 1)) * 4 + 2 * padding
    }

    private func height(of view: NSView) -> CGFloat {
        if let sub = view as? SidebarMenuSubView { return sub.contentHeight }
        let h = view.intrinsicContentSize.height
        return h == NSView.noIntrinsicMetric ? 32 : h
    }

    public override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: contentHeight) }

    public override func layout() {
        super.layout()
        var y = padding
        for row in rows {
            let h = height(of: row)
            var w = bounds.width - 2 * padding
            if let button = row as? SidebarMenuButtonView, button.size == .icon { w = 32 }
            row.frame = NSRect(x: padding, y: y, width: w, height: h)
            y += h + 4
        }
    }
}

/// `SidebarMenuSub`: 14px side margins, 1px left border in `--sidebar-border`, 10px x 2px padding,
/// sub-buttons 4px apart, the whole list nudged right 1px and each button back left 1px.
public final class SidebarMenuSubView: DSView {
    public let rows: [SidebarMenuButtonView]
    private let border = CALayer()

    public init(_ rows: [SidebarMenuButtonView]) {
        self.rows = rows
        super.init(frame: .zero)
        border.actions = ["frame": NSNull(), "position": NSNull(), "bounds": NSNull(), "backgroundColor": NSNull()]
        layer?.addSublayer(border)
        rows.forEach(addSubview)
    }

    public var contentHeight: CGFloat { CGFloat(rows.count) * 28 + CGFloat(max(0, rows.count - 1)) * 4 + 4 }

    public override func layout() {
        super.layout()
        let left: CGFloat = 14 + 1 // margin + translate-x-px
        border.frame = CGRect(x: left, y: 0, width: 1, height: bounds.height)
        var y: CGFloat = 2
        for row in rows {
            // border 1 + padding 10, then the button's own -1px translate.
            row.frame = NSRect(x: left + 1 + 10 - 1, y: y, width: max(0, bounds.width - 2 * 14 - 1 - 20), height: 28)
            y += 28 + 4
        }
    }

    public override func updateLayer() {
        border.backgroundColor = Themed.color(\.sidebarBorder, sidebar: true).cgColor(in: self)
    }
}
