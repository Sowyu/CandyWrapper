import AppKit
import DesignSystem

/// ChatView.tsx:11341-11354. Visible only during a file drag, never a hit target.
final class ThreadFileDropOverlay: DSView {
    private let label = LabelView("Drop files to attach", font: DSFont.ui(14, weight: .medium))
    private let icon = IconView(name: .paperclip, size: 16)
    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(label); addSubview(icon)
        setAccessibilityRole(.staticText); setAccessibilityLabel("Drop files to attach")
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var wantsUpdateLayer: Bool { false }
    override func draw(_ rect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 16, yRadius: 16)
        Themed.color(\.primary, 0.035).setFill(); path.fill()
        Themed.color(\.primary, 0.6).setStroke(); path.lineWidth = 2
        path.setLineDash([6, 4], count: 2, phase: 0); path.stroke()
        let pill = NSBezierPath(roundedRect: NSRect(x: bounds.midX - 110, y: bounds.midY - 21, width: 220, height: 42), xRadius: 21, yRadius: 21)
        Themed.color(\.background, 0.95).setFill(); pill.fill()
        Themed.color(\.primary, 0.25).setStroke(); pill.lineWidth = 1; pill.stroke()
    }
    override func layout() {
        super.layout()
        icon.strokeColor = Themed.color(\.primary)
        icon.frame = NSRect(x: bounds.midX - 91, y: bounds.midY - 8, width: 16, height: 16)
        label.frame = NSRect(x: bounds.midX - 67, y: bounds.midY - 10, width: 163, height: 20)
    }
}
