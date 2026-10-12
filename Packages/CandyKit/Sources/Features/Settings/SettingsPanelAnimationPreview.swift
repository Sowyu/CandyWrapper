import AppKit
import DesignSystem

/// `PanelAnimationsPreview` (PanelAnimationsPreview.tsx:5-63): a miniature window whose sidebar (`w-4`), right
/// panel (`w-5`) and terminal strip (`h-2`, `border-t border-border/70`) close and open on each click, with
/// `transition-[width,height,border-width] ease-out` over the setting's duration (`motion-reduce:transition-none`).
/// Each click retargets from where the parts are. Nothing runs between clicks.
final class SettingsPanelAnimationPreview: ControlView {
    private let left = CALayer(), right = CALayer(), terminal = CALayer(), terminalBorder = CALayer(), terminalLine = CALayer()
    private var lines: [CALayer] = []
    private var open = true

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        setAccessibilityLabel("Replay panel animation preview")
        terminal.masksToBounds = true
        left.masksToBounds = true
        right.masksToBounds = true
        for part in [left, right, terminal] { layer?.addSublayer(part) }
        terminal.addSublayer(terminalBorder)
        terminal.addSublayer(terminalLine)
        for _ in 0..<3 { let line = CALayer(); lines.append(line); layer?.addSublayer(line) }
        for part in parts { part.actions = Self.still }
        action = { [weak self] in
            guard let self else { return }
            open.toggle()
            // A reversal mid-way takes the share of the duration it travels back, as a CSS transition does.
            let shown = (left.presentation() ?? left).bounds.width
            place(duration: SettingsPanelMotion.duration * min(1, abs(shown - (open ? 16 : 0)) / 16))
        }
    }

    private var parts: [CALayer] { [left, right, terminal, terminalBorder, terminalLine] + lines }
    private static let still: [String: CAAction] = ["position": NSNull(), "bounds": NSNull(), "frame": NSNull(), "backgroundColor": NSNull(), "hidden": NSNull()]

    override var intrinsicContentSize: NSSize { NSSize(width: 112, height: 40) }

    override func updateLayer() {
        super.updateLayer()
        layer?.cornerRadius = 8; layer?.borderWidth = 1
        layer?.borderColor = Themed.color(\.border).cgColor(in: self)
        layer?.backgroundColor = Themed.color(\.background).cgColor(in: self)
        left.backgroundColor = Themed.color(\.sidebar).cgColor(in: self)
        right.backgroundColor = Themed.color(\.muted).cgColor(in: self)
        terminal.backgroundColor = Themed.color(\.foreground, 0.05).cgColor(in: self)
        terminalBorder.backgroundColor = Themed.color(\.border, 0.7).cgColor(in: self)
        terminalLine.backgroundColor = Themed.color(\.mutedForeground, 0.25).cgColor(in: self)
        for part in [left, right] { part.cornerRadius = 6 }
        for (i, line) in lines.enumerated() {
            line.backgroundColor = Themed.color(\.mutedForeground, 0.25 - CGFloat(i) * 0.05).cgColor(in: self)
            line.cornerRadius = 1
        }
    }

    private var placedSize: NSSize?
    override func layout() {
        super.layout()
        // Hover and press relayouts must not cut a transition short.
        guard placedSize != bounds.size else { return }
        placedSize = bounds.size
        place(duration: 0)
    }

    /// `flex p-1` inside a 1px border: sidebar, a `flex-1 px-1` column (three `h-0.5` lines at `pt-1 gap-1`
    /// over the terminal strip), right panel. Closed, the side panels and the strip are 0 wide or tall.
    private func place(duration: TimeInterval) {
        let inset: CGFloat = 5, height = bounds.height - 2 * inset
        let leftWidth: CGFloat = open ? 16 : 0, rightWidth: CGFloat = open ? 20 : 0, stripHeight: CGFloat = open ? 8 : 0
        let x = inset + leftWidth + 4
        let width = max(0, bounds.width - inset - rightWidth - 4 - x)
        var frames: [(CALayer, CGRect)] = [
            (left, CGRect(x: inset, y: inset, width: leftWidth, height: height)),
            (right, CGRect(x: bounds.width - inset - rightWidth, y: inset, width: rightWidth, height: height)),
            (terminal, CGRect(x: x, y: bounds.height - inset - stripHeight, width: width, height: stripHeight)),
            // The strip's content stays at its open size and is clipped as the strip shrinks.
            (terminalBorder, CGRect(x: 0, y: 0, width: width, height: open ? 1 : 0)),
            (terminalLine, CGRect(x: 8, y: 4, width: max(0, (width - 16) * 2 / 3), height: 1)),
        ]
        for (i, line) in lines.enumerated() {
            frames.append((line, CGRect(x: x, y: inset + 4 + CGFloat(i) * 6, width: width * (1 - CGFloat(i) * 0.2), height: 2)))
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (part, frame) in frames {
            if duration > 0 {
                // Start from what shows now, so a click mid-transition turns it around.
                let shown = part.presentation() ?? part
                for (key, from, to) in [("position", NSValue(point: shown.position), NSValue(point: CGPoint(x: frame.midX, y: frame.midY))),
                                        ("bounds", NSValue(rect: shown.bounds), NSValue(rect: CGRect(origin: .zero, size: frame.size)))] {
                    let animation = CABasicAnimation(keyPath: key)
                    animation.fromValue = from
                    animation.toValue = to
                    animation.duration = duration
                    animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    part.add(animation, forKey: key)
                }
            } else {
                part.removeAllAnimations()
            }
            part.frame = frame
        }
        CATransaction.commit()
    }
}
