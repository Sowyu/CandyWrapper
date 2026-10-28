import AppKit
import DesignSystem

/// `EnvironmentMachineIcon` (apps/web/src/components/EnvironmentMachineIcon.tsx): lucide glyphs plus the
/// two Apple desktops T3 draws to lucide's grammar.
public enum EnvironmentMachineIcon {
    public static func definition(_ kind: String) -> IconDefinition {
        let box = IconViewBox(x: 0, y: 0, width: 24, height: 24)
        switch kind {
        case "mac-mini":
            if ThreadDesign.uses3814 {
                return IconDefinition(viewBox: box, elements: [
                    IconElement(.rect(x: 3, y: 6, w: 18, h: 12, rx: 2.5, ry: 2.5), IconPaint(stroke: .current, strokeWidth: 1.75, lineCap: .round, lineJoin: .round)),
                    IconElement(.circle(cx: 7.5, cy: 12, r: 1), IconPaint(fill: .current))])
            }
            return IconDefinition(viewBox: box, elements: [
                IconElement(.rect(x: 2, y: 8, w: 20, h: 8, rx: 2, ry: 2)), IconElement(.path(d: "M6 12h.01"))])
        case "mac-studio":
            return IconDefinition(viewBox: box, elements: [
                IconElement(.rect(x: 3, y: 5, w: 18, h: 14, rx: 2, ry: 2)), IconElement(.path(d: "M7 15h.01M11 15h.01M15 15h.01"))])
        case "cloud": return IconName.cloud.definition
        case "desktop": return IconName.monitor.definition
        case "laptop": return IconName.laptop.definition
        // ponytail: T3 draws a Tux glyph for `linux`; it isn't in the icon set yet, so it shows the server glyph
        default: return IconName.server.definition
        }
    }

    static func view(_ kind: String, size: CGFloat, color: NSColor) -> IconView {
        IconView(definition: definition(kind), size: size, color: color)
    }
}

/// Holds one machine glyph and swaps it when the kind changes.
final class EnvironmentMachineGlyphView: NSView {
    var kind: String? { didSet { if kind != oldValue { rebuild() } } }
    var color: NSColor = .labelColor { didSet { glyph?.strokeColor = color } }
    private var glyph: IconView?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func rebuild() {
        glyph?.removeFromSuperview()
        glyph = nil
        guard let kind else { return }
        let v = EnvironmentMachineIcon.view(kind, size: bounds.width > 0 ? bounds.width : 14, color: color)
        v.frame = bounds
        v.autoresizingMask = [.width, .height]
        addSubview(v)
        glyph = v
    }
}
