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
    var onPick: ((RuntimeMode) -> Void)?
    private var focused: Int?

    init(modes: [RuntimeMode], selected: RuntimeMode) {
        self.modes = modes; self.selected = selected
        super.init(frame: .zero)
        heading.lineHeight = 16; title.lineHeight = 20
        detail.font = DSFont.ui(12); detail.lineHeight = 16; detail.color = Themed.color(\.mutedForeground)
        for view in [heading, track, title, detail] as [NSView] { addSubview(view) }
        for mode in modes {
            let info = ComposerPickers.modes[mode]!
            let choice = PermissionChoice(icon: mode == .fullAccess ? ComposerPickers.fullAccessGlyph : info.icon.definition, checked: mode == selected)
            choice.setAccessibilityLabel(info.label); choice.setAccessibilityHelp(info.description)
            choice.action = { [weak self] in self?.onPick?(mode) }
            choice.onPreview = { [weak self] lit in self?.preview(lit ? mode : nil) }
            track.addSubview(choice); buttons.append(choice)
        }
        preview(nil)
    }
    private func preview(_ mode: RuntimeMode?) {
        let info = ComposerPickers.modes[mode ?? selected]!
        title.text = info.label; title.color = Themed.color(mode == nil || mode == selected ? \.foreground : \.mutedForeground)
        detail.text = info.description; needsLayout = true
    }
    func handleKey(_ key: PopupKey) -> Bool {
        guard !modes.isEmpty else { return false }
        let current = focused ?? modes.firstIndex(of: selected) ?? 0
        let next: Int
        switch key {
        case .left: next = (current + modes.count - 1) % modes.count
        case .right: next = (current + 1) % modes.count
        case .home: next = 0
        case .end: next = modes.count - 1
        case .enter, .space: onPick?(modes[current]); return true
        default: return false
        }
        focused = next
        for (i, button) in buttons.enumerated() { var state = button.state; state.focusVisible = i == next; button.previewState(state) }
        preview(modes[next]); return true
    }
    override func updateLayer() {
        track.layer?.cornerRadius = 8; track.layer?.backgroundColor = Themed.color(\.input, 0.4).cgColor(in: self)
    }
    override func layout() {
        super.layout()
        let w = bounds.width - 16
        heading.frame = NSRect(x: 8, y: 6, width: w, height: 16)
        track.frame = NSRect(x: 8, y: 28, width: w, height: 28)
        let bw = (w - 4 - CGFloat(max(0, buttons.count - 1)) * 2) / CGFloat(max(1, buttons.count))
        for (i, button) in buttons.enumerated() { button.frame = NSRect(x: 2 + CGFloat(i) * (bw + 2), y: 2, width: bw, height: 24) }
        title.frame = NSRect(x: 8, y: 62, width: w, height: 20)
        detail.frame = NSRect(x: 8, y: 84, width: w, height: 32)
    }
}

private final class PermissionChoice: ControlView {
    let checked: Bool
    let icon: IconView
    var onPreview: ((Bool) -> Void)?
    init(icon: IconDefinition, checked: Bool) {
        self.checked = checked; self.icon = IconView(definition: icon, size: 14)
        super.init(frame: .zero); scalesWhenPressed = false; addSubview(self.icon)
        setAccessibilityRole(.radioButton); setAccessibilityValue(checked ? 1 : 0)
    }
    override func stateDidChange(from old: State) { super.stateDidChange(from: old); onPreview?(state.hovered || state.focusVisible) }
    override func updateLayer() {
        layer?.cornerRadius = 6
        layer?.backgroundColor = checked ? Themed.color(\.input, 0.72).cgColor(in: self) : state.hoverOrPressed ? Themed.color(\.accent).cgColor(in: self) : nil
        layer?.borderWidth = state.focusVisible ? 2 : 0; layer?.borderColor = Themed.color(\.ring).cgColor(in: self)
        icon.strokeColor = Themed.color(checked || state.hovered ? \.foreground : \.mutedForeground)
    }
    override func layout() { super.layout(); icon.frame = NSRect(x: (bounds.width - 14) / 2, y: 5, width: 14, height: 14) }
}

/// A traits menu and its Permissions section use the same popup and close after either pick.
final class ComposerOptionsMenu: DSView, PickerPopupBody {
    let traits: PickerMenuView?
    let permissions: ComposerPermissionsView
    var onClose: (() -> Void)?
    private let divider = DSView()
    private var permissionsFocused: Bool
    init(entries: [PickerMenuEntry]?, modes: [RuntimeMode], selected: RuntimeMode, onPick: @escaping (RuntimeMode) -> Void) {
        permissionsFocused = entries == nil
        traits = entries.map { PickerMenuView(entries: $0, style: .menu, minimumWidth: 294) }
        permissions = ComposerPermissionsView(modes: modes, selected: selected)
        super.init(frame: .zero)
        if let traits { addSubview(traits); traits.onClose = { [weak self] in self?.onClose?() }; addSubview(divider) }
        addSubview(permissions)
        permissions.onPick = { [weak self] mode in onPick(mode); self?.onClose?() }
    }
    var naturalSize: CGSize { CGSize(width: max(296, traits?.naturalSize.width ?? 0), height: (traits?.naturalSize.height ?? 0) + (traits == nil ? 130 : 131)) }
    func focusPermissions() { permissionsFocused = true; traits?.highlightedIndex = nil }
    func handleKey(_ key: PopupKey) -> Bool {
        if key == .escape { onClose?(); return true }
        if key == .left || key == .right { focusPermissions() }
        if key == .down, let traits, traits.highlightedIndex == traits.selectableIndices.last { focusPermissions(); return true }
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
        permissions.frame = NSRect(x: 4, y: top + (traits == nil ? 4 : 5), width: bounds.width - 8, height: 122)
    }
}
