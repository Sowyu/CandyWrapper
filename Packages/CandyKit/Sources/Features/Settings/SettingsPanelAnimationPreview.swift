import AppKit
import DesignSystem

/// PanelAnimationsPreview.tsx:8-82. Click toggles the static miniature; no replay timer.
final class SettingsPanelAnimationPreview: ControlView {
    private let left = DSView(), right = DSView(), terminal = DSView()
    private var lines: [DSView] = []
    private var open = true
    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        setAccessibilityLabel("Replay panel animation preview")
        for view in [left, right, terminal] { addSubview(view) }
        for _ in 0..<3 { let line = DSView(); lines.append(line); addSubview(line) }
        action = { [weak self] in
            guard let self else { return }
            open.toggle(); needsLayout = true; layoutSubtreeIfNeeded()
            SettingsPanelMotion.reveal(left, offset: CGSize(width: open ? -16 : 16, height: 0))
            SettingsPanelMotion.reveal(right, offset: CGSize(width: open ? 20 : -20, height: 0))
            SettingsPanelMotion.reveal(terminal, offset: CGSize(width: 0, height: open ? 8 : -8))
        }
    }
    override var intrinsicContentSize: NSSize { NSSize(width: 176, height: 40) }
    override func updateLayer() {
        super.updateLayer()
        layer?.cornerRadius = 8; layer?.borderWidth = 1
        layer?.borderColor = Themed.color(\.border).cgColor(in: self)
        layer?.backgroundColor = Themed.color(\.background).cgColor(in: self)
        left.layer?.backgroundColor = Themed.color(\.sidebar).cgColor(in: self)
        right.layer?.backgroundColor = Themed.color(\.muted).cgColor(in: self)
        terminal.layer?.backgroundColor = Themed.color(\.foreground, 0.05).cgColor(in: self)
        for v in [left, right] { v.layer?.cornerRadius = 6 }
        for (i, line) in lines.enumerated() {
            line.layer?.backgroundColor = Themed.color(\.mutedForeground, 0.25 - CGFloat(i) * 0.05).cgColor(in: self)
            line.layer?.cornerRadius = 1
        }
    }
    override func layout() {
        super.layout()
        left.frame = NSRect(x: open ? 5 : -16, y: 5, width: 16, height: 30)
        right.frame = NSRect(x: open ? bounds.width - 25 : bounds.width, y: 5, width: 20, height: 30)
        let x: CGFloat = open ? 25 : 9
        let width = bounds.width - x - (open ? 29 : 9)
        for (i, line) in lines.enumerated() { line.frame = NSRect(x: x, y: 9 + CGFloat(i) * 6, width: width * (1 - CGFloat(i) * 0.2), height: 2) }
        terminal.frame = NSRect(x: x, y: open ? 27 : 40, width: width, height: 8)
    }
}
