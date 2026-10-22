import AppKit
import DesignSystem

/// Dither's "Working for 13s", after Capy's: each digit that changes rolls up out of its slot as the next one rolls in,
/// and the focus shimmer sweeps the whole line. The roll plays once a second on the timer's own tick, and the shimmer is
/// a `LoopingAnimation`, so both stop when the window is covered, the row hides or Reduce Motion is on.
final class DitherWorkingTicker: DSView {
    private let base = RollingTextView()
    private let bright = RollingTextView()
    private let band = CAGradientLayer()
    private var loop: LoopingAnimation?
    var fastMode = false { didSet { if fastMode != oldValue { band.removeAnimation(forKey: "shine"); loop?.update() } } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        base.color = TL.c(\.mutedForeground)
        bright.color = TL.c(\.foreground)
        addSubview(base)
        addSubview(bright)
        ShineLabelView.makeFocusBand(band)
        band.startPoint = CGPoint(x: 0, y: 0.5)
        band.endPoint = CGPoint(x: 1, y: 0.5)
        bright.layer?.mask = band
        loop = LoopingAnimation(view: self, key: "shine", layer: { [weak self] in self?.band }) { [weak self] in
            ShineLabelView.sweep(to: (self?.bright.textWidth ?? 0) + 108, duration: self?.fastMode == true ? 2.2 / 2.5 : 2.2)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Sets `prefix` and `value`; `animated` rolls the characters of `value` that changed.
    func set(prefix: String, value: String, animated: Bool) {
        base.set(prefix: prefix, value: value, animated: animated)
        bright.set(prefix: prefix, value: value, animated: animated)
        setAccessibilityValue(prefix + value)
        needsLayout = true
    }

    var textWidth: CGFloat { base.textWidth }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        base.frame = bounds
        bright.frame = bounds
        CATransaction.begin(); CATransaction.setDisableActions(true)
        band.frame = CGRect(x: -72, y: 0, width: 72, height: bounds.height)
        CATransaction.commit()
        band.removeAnimation(forKey: "shine")
        loop?.update()
    }

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); loop?.windowChanged() }
    override func viewDidHide() { super.viewDidHide(); loop?.update() }
    override func viewDidUnhide() { super.viewDidUnhide(); loop?.update() }
}

/// A fixed prefix and a value whose characters each sit in their own slot, so one can roll on its own. The view clips
/// to its line, so a rolling character leaves through its top edge.
final class RollingTextView: DSView {
    static let font = TL.tabular(14)
    static let duration: CFTimeInterval = 0.32
    var color: NSColor = .labelColor { didSet { prefix.color = color; slots.forEach { $0.label.color = color } } }
    private let prefix = LabelView("", font: RollingTextView.font)
    private var slots: [Slot] = []
    private var value = ""

    @MainActor private final class Slot {
        let clip = DSView()
        var label: LabelView
        /// Nil until the slot first shows a character.
        var character: Character?
        var width: CGFloat = 0
        init(color: NSColor) {
            label = RollingTextView.label(" ", color: color)
            clip.addSubview(label)
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        prefix.lineHeight = TL.relaxed
        addSubview(prefix)
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    static func width(_ c: Character) -> CGFloat { ceil((String(c) as NSString).size(withAttributes: [.font: font]).width * 2) / 2 }

    static func label(_ c: Character, color: NSColor) -> LabelView {
        let l = LabelView(String(c), font: font, color: color)
        l.lineHeight = TL.relaxed
        l.truncates = false
        return l
    }

    var textWidth: CGFloat { ceil(prefix.textWidth) + slots.reduce(0) { $0 + $1.width } }

    func set(prefix text: String, value next: String, animated: Bool) {
        prefix.text = text
        guard next != value else { return }
        let new = Array(next)
        value = next
        let roll = animated && !Motion.reduced && window != nil
        // Slots line up from the right, where the seconds change: "9s" to "10s" rolls the 9 and adds a slot.
        while slots.count > new.count { let s = slots.removeFirst(); s.clip.removeFromSuperview() }
        while slots.count < new.count {
            let s = Slot(color: color)
            addSubview(s.clip)
            slots.insert(s, at: 0)
        }
        for (i, slot) in slots.enumerated() {
            let c = new[i]
            guard c != slot.character else { continue }
            slot.character = c
            slot.width = Self.width(c)
            let incoming = Self.label(c, color: color)
            let outgoing = slot.label
            slot.label = incoming
            slot.clip.addSubview(incoming)
            if roll {
                rollIn(incoming, out: outgoing)
            } else {
                outgoing.removeFromSuperview()
            }
        }
        needsLayout = true
    }

    /// The old character leaves upward as the new one rises from below, each fading across the slot's edge.
    private func rollIn(_ incoming: LabelView, out outgoing: LabelView) {
        let h = TL.relaxed
        // Flipped layers: a negative y moves up.
        func move(_ layer: CALayer?, from: CGFloat, to: CGFloat, opacity: (CGFloat, CGFloat)) {
            let group = CAAnimationGroup()
            let y = CABasicAnimation(keyPath: "transform.translation.y")
            y.fromValue = from; y.toValue = to
            let o = CABasicAnimation(keyPath: "opacity")
            o.fromValue = opacity.0; o.toValue = opacity.1
            group.animations = [y, o]
            group.duration = Self.duration
            group.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
            layer?.add(group, forKey: "roll")
        }
        move(incoming.layer, from: h * 0.8, to: 0, opacity: (0, 1))
        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { outgoing.removeFromSuperview() } }
        outgoing.layer?.opacity = 0
        move(outgoing.layer, from: 0, to: -h * 0.8, opacity: (1, 0))
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        let pw = ceil(prefix.textWidth)
        prefix.frame = NSRect(x: 0, y: 0, width: pw, height: bounds.height)
        var x = pw
        for slot in slots {
            slot.clip.frame = NSRect(x: x, y: 0, width: slot.width, height: bounds.height)
            for l in slot.clip.subviews { l.frame = NSRect(x: 0, y: 0, width: slot.width + 2, height: bounds.height) }
            x += slot.width
        }
    }
}
