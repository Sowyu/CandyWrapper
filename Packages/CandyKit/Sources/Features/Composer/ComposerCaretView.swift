import AppKit
import QuartzCore

/// Chromium's caret in the prompt editor (`FrameCaret`): 1px wide, the height of the font's ascent and
/// descent, in the text color (the editor sets no `caret-color`). It blinks hard, 500ms on and 500ms
/// off (Chromium's default interval when `NSTextInsertionPointBlinkPeriodOn` and `Off` are unset), and
/// shows solid again after every move or edit.
///
/// The blink is a repeating discrete keyframe animation, so the render server toggles it and the
/// app does not wake while the caret sits still. AppKit's own indicator (about 2px, fading) stays
/// hidden. A drawn caret on AppKit's blink timer cost 2.25 wakeups a second at idle.
final class ComposerCaretView: NSView {
    static let blinkKey = "blink"
    static let blink: CAKeyframeAnimation = {
        let a = CAKeyframeAnimation(keyPath: "opacity")
        a.values = [1, 0]
        a.keyTimes = [0, 0.5, 1]
        a.calculationMode = .discrete
        a.duration = 1
        a.repeatCount = .infinity
        a.isRemovedOnCompletion = false
        return a
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        isHidden = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }

    /// Shows the caret at `rect`. `restart` starts the blink over from solid, as a caret move does.
    func show(_ rect: NSRect, color: CGColor, restart: Bool) {
        guard let layer else { return }
        let wasHidden = isHidden
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if frame != rect { frame = rect }
        if layer.backgroundColor != color { layer.backgroundColor = color }
        isHidden = false
        if restart || wasHidden || layer.animation(forKey: Self.blinkKey) == nil {
            layer.removeAnimation(forKey: Self.blinkKey)
            layer.add(Self.blink, forKey: Self.blinkKey)
        }
        CATransaction.commit()
    }

    /// Hides the caret and drops the blink, so an unfocused editor holds no animation.
    func hide() {
        guard !isHidden else { return }
        isHidden = true
        layer?.removeAnimation(forKey: Self.blinkKey)
    }
}

/// The prompt's selection as Chromium paints it: whole line boxes in `ComposerEditor.selectionColor`,
/// under the text. TextKit's own band (glyph height) is drawn clear.
final class ComposerSelectionView: NSView {
    var bands: [NSRect] = [] {
        didSet {
            guard bands != oldValue else { return }
            isHidden = bands.isEmpty
            needsDisplay = true
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        isHidden = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        ComposerEditor.selectionColor.setFill()
        for band in bands where band.intersects(dirtyRect) { band.fill(using: .sourceOver) }
    }
}
