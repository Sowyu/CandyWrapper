import AppKit
import DesignSystem
import T3Protocol

/// T3 3824 ComposerFooterControls.tsx:161-247. Permissions share one horizontal toggle.
final class ComposerPermissionsView: DSView {
    private let heading = LabelView("Permissions", font: DSFont.ui(12, weight: .medium), color: Themed.color(\.mutedForeground))
    private let track = DSView()
    private let title = LabelView("", font: DSFont.ui(14))
    private let detail = TextBlockView()
    private var buttons: [PermissionChoice] = []
    private let modes: [RuntimeMode]
    private let selected: RuntimeMode
    /// CandyWrapper's Unrestricted segment after Full access (`UnrestrictedAccess`), nil when not offered.
    private let unrestricted: UnrestrictedAccess.State?
    /// The segments: T3's modes, then Unrestricted as `nil`.
    private let choices: [RuntimeMode?]
    private var selectedIndex: Int? { unrestricted?.on == true && selected == .fullAccess ? choices.count - 1 : choices.firstIndex(of: selected) }
    var onPick: ((RuntimeMode) -> Void)?
    /// Unrestricted picked (true) or turned off (false).
    var onUnrestricted: ((Bool) -> Void)?
    private var focused: Int?
    private var turnOff: ButtonView?
    /// The "Turn off Unrestricted" row under the description while it is on, plus the description's lines past two.
    var extraHeight: CGFloat { turnOff == nil ? 0 : detailHeight }
    /// The description's height. Two lines, or with the Turn off row as many lines as Unrestricted's hint takes at
    /// the menu's narrowest width (296 less padding), so the row sits below its last line.
    private var detailHeight: CGFloat = 32
    /// Redesign lists the modes as rows, each with its icon and name, so they can be compared before one is picked
    /// (round-1 review C8, 2026-11-26: "five similar unlabeled icon targets"). The trigger on the composer stays an
    /// icon, as the user decided. The description under the rows follows the hovered or focused row.
    let rows: Bool
    static let rowHeight: CGFloat = 28
    /// The section's height in its menu.
    var height: CGFloat {
        guard rows else { return 122 + extraHeight }
        return 28 + CGFloat(buttons.count) * Self.rowHeight + 6 + detailHeight + (turnOff == nil ? 0 : 4 + 24) + 6
    }

    init(modes: [RuntimeMode], selected: RuntimeMode, unrestricted: UnrestrictedAccess.State? = nil) {
        self.modes = modes; self.selected = selected
        self.unrestricted = modes.contains(.fullAccess) ? unrestricted : nil
        choices = modes.map { $0 } + (self.unrestricted == nil ? [] : [nil])
        rows = ThemeRuntime.isDither(dark: NSApp?.effectiveAppearance.isDark ?? true)
        super.init(frame: .zero)
        heading.lineHeight = 16; title.lineHeight = 20
        detail.font = DSFont.ui(12); detail.lineHeight = 16; detail.color = Themed.color(\.mutedForeground)
        for view in [heading, track, title, detail] as [NSView] { addSubview(view) }
        for (i, mode) in choices.enumerated() {
            let info = Self.info(mode, unrestricted: self.unrestricted)
            let choice = PermissionChoice(icon: mode == .fullAccess ? ComposerPickers.fullAccessIcon(dark: NSApp.effectiveAppearance.isDark) : info.icon.definition, checked: i == selectedIndex,
                                          label: rows ? info.label : nil)
            choice.setAccessibilityLabel(info.label); choice.setAccessibilityHelp(info.description)
            choice.action = { [weak self] in self?.pick(i) }
            choice.onPreview = { [weak self] lit in self?.preview(lit ? i : nil) }
            track.addSubview(choice); buttons.append(choice)
        }
        if self.unrestricted?.on == true {
            let button = ButtonView("Turn off Unrestricted", variant: .outline, size: .xs)
            button.setTooltip("Turns it off for every Claude thread on this machine.")
            button.action = { [weak self] in self?.onUnrestricted?(false) }
            addSubview(button); turnOff = button
        }
        preview(nil)
        if turnOff != nil { detailHeight = max(32, detail.layout(forWidth: 272).height) }
        title.isHidden = rows
        // The track is the segmented control's; rows sit on the menu itself.
        track.isHidden = rows
        if rows { for b in buttons { b.removeFromSuperview(); addSubview(b) } }
    }
    static func info(_ mode: RuntimeMode?, unrestricted: UnrestrictedAccess.State?) -> ComposerPickers.ModeInfo {
        guard let mode else {
            return .init(label: UnrestrictedAccess.label, description: unrestricted?.unsupportedHint ?? UnrestrictedAccess.description, icon: .triangleAlert)
        }
        return ComposerPickers.modes[mode]!
    }
    private func pick(_ index: Int) {
        if let mode = choices[index] { onPick?(mode) } else { onUnrestricted?(true) }
    }
    private func preview(_ index: Int?) {
        let shown = index ?? selectedIndex
        let info = Self.info(shown.map { choices[$0] } ?? selected, unrestricted: unrestricted)
        title.text = info.label; title.color = Themed.color(index == nil || index == selectedIndex ? \.foreground : \.mutedForeground)
        detail.text = info.description; needsLayout = true
    }
    func handleKey(_ key: PopupKey) -> Bool {
        guard !choices.isEmpty else { return false }
        let current = focused ?? selectedIndex ?? 0
        let next: Int
        switch key {
        case .left: next = (current + choices.count - 1) % choices.count
        case .right: next = (current + 1) % choices.count
        // Rows move down and up too; above the first row the key goes back to the menu (the traits above).
        case .down where rows: next = min(choices.count - 1, focused == nil ? current : current + 1)
        case .up where rows:
            guard current > 0 else { return false }
            next = current - 1
        case .home: next = 0
        case .end: next = choices.count - 1
        case .enter, .space: pick(current); return true
        default: return false
        }
        focused = next
        for (i, button) in buttons.enumerated() { var state = button.state; state.focusVisible = i == next; button.previewState(state) }
        preview(next); return true
    }
    override func updateLayer() {
        // Redesign's light track is the reasoning levels' quiet fill (ComposerFooterGroupView).
        let fill = RedesignTokens.Segment.light(in: self) ? RedesignTokens.Segment.trackFill : Themed.color(\.input, 0.4)
        track.layer?.cornerRadius = ComposerFooterGroupView.radius; track.layer?.backgroundColor = fill.cgColor(in: self)
    }
    override func layout() {
        super.layout()
        let w = bounds.width - 16
        heading.frame = NSRect(x: 8, y: 6, width: w, height: 16)
        if rows {
            var y: CGFloat = 28
            for button in buttons {
                button.frame = NSRect(x: 0, y: y, width: bounds.width, height: Self.rowHeight)
                y += Self.rowHeight
            }
            detail.frame = NSRect(x: 8, y: y + 6, width: w, height: detailHeight)
            if let turnOff { turnOff.frame = NSRect(x: 8, y: detail.frame.maxY + 4, width: turnOff.intrinsicContentSize.width, height: 24) }
            return
        }
        track.frame = NSRect(x: 8, y: 28, width: w, height: 28)
        // No gaps; only the outer ends round (`first:rounded-l-md last:rounded-r-md`, #26514 at 4928). Redesign rounds each
        // fill on its own, as the reasoning levels do.
        let bw = (w - 4) / CGFloat(max(1, buttons.count))
        for (i, button) in buttons.enumerated() {
            button.frame = NSRect(x: 2 + CGFloat(i) * bw, y: 2, width: bw, height: 24)
            button.first = i == 0; button.last = i == buttons.count - 1
        }
        title.frame = NSRect(x: 8, y: 62, width: w, height: 20)
        detail.frame = NSRect(x: 8, y: 84, width: w, height: detailHeight)
        if let turnOff { turnOff.frame = NSRect(x: 8, y: 88 + detailHeight, width: turnOff.intrinsicContentSize.width, height: 24) }
    }
}

private final class PermissionChoice: ControlView {
    let checked: Bool
    let icon: IconView
    var first = true { didSet { needsDisplay = true } }
    var last = true { didSet { needsDisplay = true } }
    var onPreview: ((Bool) -> Void)?
    /// Redesign's row form: the mode's name after the icon and a check on the chosen one.
    private let label: LabelView?
    private let check: IconView?
    init(icon: IconDefinition, checked: Bool, label: String? = nil) {
        self.checked = checked; self.icon = IconView(definition: icon, size: 14)
        self.label = label.map { LabelView($0, font: DSFont.ui(13)) }
        check = label != nil && checked ? IconView(name: .check, size: 14) : nil
        super.init(frame: .zero); scalesWhenPressed = false; addSubview(self.icon)
        if let l = self.label { l.lineHeight = 16; addSubview(l) }
        if let check { addSubview(check) }
        setAccessibilityRole(.radioButton); setAccessibilityValue(checked ? 1 : 0)
    }
    override func stateDidChange(from old: State) { super.stateDidChange(from: old); onPreview?(state.hovered || state.focusVisible) }
    override func updateLayer() {
        if let label, let layer {
            // A menu row: the hover fill inset on the menu's control corner, the chosen row in the text color.
            let lit = state.hoverOrPressed || state.focusVisible
            layer.backgroundColor = nil
            fill.backgroundColor = lit ? RedesignTokens.State.fill(RedesignTokens.State.hover, dark: effectiveAppearance.isDark).cgColor : nil
            let ink = Themed.color(checked || lit ? \.foreground : \.mutedForeground)
            label.color = ink; icon.strokeColor = ink; check?.strokeColor = Themed.color(\.foreground)
            return
        }
        if ThemeRuntime.isDither(dark: effectiveAppearance.isDark), let layer {
            ComposerFooterSegmentView.paint(layer, in: self, checked: checked, hovered: state.hoverOrPressed, focused: state.focusVisible, first: first, last: last)
            icon.strokeColor = Themed.color(checked || state.hovered ? \.contrastForeground : \.contrastMutedForeground)
            return
        }
        layer?.cornerRadius = 6
        layer?.shadowOpacity = 0
        var corners: CACornerMask = []
        if first { corners.formUnion([.layerMinXMinYCorner, .layerMinXMaxYCorner]) }
        if last { corners.formUnion([.layerMaxXMinYCorner, .layerMaxXMaxYCorner]) }
        layer?.maskedCorners = corners
        layer?.backgroundColor = checked ? Themed.color(\.input, 0.72).cgColor(in: self) : state.hoverOrPressed ? Themed.color(\.accent).cgColor(in: self) : nil
        layer?.borderWidth = state.focusVisible ? 2 : 0; layer?.borderColor = Themed.color(\.ring).cgColor(in: self)
        icon.strokeColor = Themed.color(checked || state.hovered ? \.foreground : \.mutedForeground)
    }
    private lazy var fill: CALayer = {
        let l = CALayer()
        l.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull()]
        l.cornerRadius = RedesignTokens.Radius.control
        layer?.insertSublayer(l, at: 0)
        return l
    }()
    override func layout() {
        super.layout()
        guard let label else { icon.frame = NSRect(x: (bounds.width - 14) / 2, y: 5, width: 14, height: 14); return }
        let midY = bounds.height / 2
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fill.frame = bounds.insetBy(dx: RedesignTokens.Space.xs, dy: 0)
        CATransaction.commit()
        icon.frame = NSRect(x: 12, y: midY - 7, width: 14, height: 14)
        check?.frame = NSRect(x: bounds.width - 12 - 14, y: midY - 7, width: 14, height: 14)
        label.frame = NSRect(x: 12 + 14 + 8, y: midY - 8, width: max(0, bounds.width - 34 - 12 - 14 - 8), height: 16)
    }
}

/// A traits menu and its Permissions section use the same popup and close after either pick.
final class ComposerOptionsMenu: DSView, PickerPopupBody {
    let traits: PickerMenuView?
    let permissions: ComposerPermissionsView
    var onClose: (() -> Void)?
    private let divider = DSView()
    private var permissionsFocused: Bool
    init(entries: [PickerMenuEntry]?, modes: [RuntimeMode], selected: RuntimeMode, unrestricted: UnrestrictedAccess.State? = nil,
         onUnrestricted: ((Bool) -> Void)? = nil, onPick: @escaping (RuntimeMode) -> Void) {
        permissionsFocused = entries == nil
        traits = entries.map { PickerMenuView(entries: $0, style: .menu, minimumWidth: 294) }
        permissions = ComposerPermissionsView(modes: modes, selected: selected, unrestricted: unrestricted)
        super.init(frame: .zero)
        if let traits { addSubview(traits); traits.onClose = { [weak self] in self?.onClose?() }; addSubview(divider) }
        addSubview(permissions)
        permissions.onPick = { [weak self] mode in onPick(mode); self?.onClose?() }
        permissions.onUnrestricted = { [weak self] on in self?.onClose?(); onUnrestricted?(on) }
    }
    var naturalSize: CGSize { CGSize(width: max(296, traits?.naturalSize.width ?? 0), height: (traits?.naturalSize.height ?? 0) + permissions.height + (traits == nil ? 8 : 9)) }
    func focusPermissions() { permissionsFocused = true; traits?.highlightedIndex = nil }
    func handleKey(_ key: PopupKey) -> Bool {
        if key == .escape { onClose?(); return true }
        if key == .left || key == .right { focusPermissions() }
        if key == .down, let traits, traits.highlightedIndex == traits.selectableIndices.last { focusPermissions(); return true }
        if key == .up, permissionsFocused, permissions.rows, permissions.handleKey(.up) { return true }
        if key == .up, permissionsFocused, let traits {
            permissionsFocused = false; traits.highlightedIndex = traits.selectableIndices.last; return true
        }
        return permissionsFocused ? permissions.handleKey(key) : traits?.handleKey(key) ?? false
    }
    override func updateLayer() { divider.layer?.backgroundColor = Themed.color(\.border).cgColor(in: self) }
    override func layout() {
        super.layout()
        let top = traits?.naturalSize.height ?? 0
        traits?.frame = NSRect(x: 0, y: 0, width: bounds.width, height: top)
        divider.frame = NSRect(x: 8, y: top + 4, width: max(0, bounds.width - 16), height: 1)
        permissions.frame = NSRect(x: 4, y: top + (traits == nil ? 4 : 5), width: bounds.width - 8, height: permissions.height)
    }
}
