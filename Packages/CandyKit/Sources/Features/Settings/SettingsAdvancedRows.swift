import AppKit
import DesignSystem
import QuartzCore

/// The in-card Advanced fold (3814 AdvancedSettings.tsx:31-41).
final class SettingsAdvancedRows: DSView, SettingsGroupRow {
    private let trigger = Trigger()
    private let rows: [any SettingsGroupRow]
    var onHeightChange: (() -> Void)?
    private(set) var isOpen = false

    init(rows: [any SettingsGroupRow]) {
        self.rows = rows
        super.init(frame: .zero)
        addSubview(trigger)
        trigger.action = { [weak self] in guard let self else { return }; self.setOpen(!self.isOpen) }
        rows.forEach { $0.isHidden = true; addSubview($0) }
    }

    func setOpen(_ open: Bool) {
        guard isOpen != open else { return }
        CollapseMotion.run(in: self) {
            isOpen = open
            trigger.open = open
            rows.forEach { $0.isHidden = !open }
            needsLayout = true
            onHeightChange?()
            enclosingScrollView?.documentView?.needsLayout = true
            enclosingScrollView?.documentView?.layoutSubtreeIfNeeded()
        }
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        40 + (isOpen ? rows.reduce(0) { $0 + 1 + $1.height(forWidth: width) } : 0)
    }
    override func layout() {
        super.layout()
        trigger.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 40)
        var y: CGFloat = 40
        for row in rows where isOpen {
            y += 1
            let h = row.height(forWidth: bounds.width)
            row.frame = NSRect(x: 0, y: y, width: bounds.width, height: h)
            y += h
        }
    }
    override var wantsUpdateLayer: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        guard isOpen else { return }
        Themed.color(\.border, 0.5).setFill()
        for row in rows { NSRect(x: 0, y: row.frame.minY - 1, width: bounds.width, height: 1).fill() }
    }

    private final class Trigger: ControlView {
        let label = LabelView("Advanced", font: DSFont.ui(12, weight: .medium), color: Themed.color(\.mutedForeground))
        let chevron = IconView(name: .chevronRight, size: 14)
        var open = false { didSet { setAccessibilityExpanded(open); needsLayout = true } }
        override init(frame: NSRect) {
            super.init(frame: frame)
            scalesWhenPressed = false
            label.lineHeight = 16
            addSubview(label)
            addSubview(chevron)
            setAccessibilityRole(.button)
            setAccessibilityLabel("Advanced")
            setAccessibilityExpanded(false)
        }
        override func stateDidChange(from old: State) { super.stateDidChange(from: old); needsDisplay = true }
        override func updateLayer() {
            label.color = Themed.color(state.hoverOrPressed ? \.foreground : \.mutedForeground)
            chevron.strokeColor = label.color
            layer?.borderWidth = state.focusVisible ? 2 : 0
            layer?.borderColor = Themed.color(\.ring).cgColor(in: self)
        }
        override func layout() {
            super.layout()
            chevron.frame = NSRect(x: 16, y: 13, width: 14, height: 14)
            label.frame = NSRect(x: 36, y: 12, width: max(0, bounds.width - 52), height: 16)
            let transform = CATransform3DMakeRotation(open ? .pi / 2 : 0, 0, 0, 1)
            for shape in chevron.shapeLayers {
                Motion.animate(shape, keyPath: "transform", to: NSValue(caTransform3D: transform), duration: 0.15)
            }
        }
    }
}
