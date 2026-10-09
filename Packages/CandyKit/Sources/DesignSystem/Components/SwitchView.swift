import AppKit
import QuartzCore

/// T3's `Switch` (`apps/web/src/components/ui/switch.tsx`), desktop values.
/// Spec: docs/research/recovered/ui-components-b.md section 3.
/// Motion as in T3: track color 200ms ease-in-out, thumb slide 150ms `ease`,
/// press stretch `scale-x-110` over 100ms after a 100ms delay, anchored on the side it rests on.
public final class SwitchView: ControlView {
    public enum Size: String, CaseIterable, Sendable {
        case `default`, sm
        /// `--thumb-size` on desktop.
        var thumb: CGFloat { self == .default ? 16 : 14 }
    }

    public var size: Size = .default { didSet { invalidateIntrinsicContentSize(); needsLayout = true } }
    public var isOn = false { didSet { if isOn != oldValue { apply(animated: true); setAccessibilityValue(isOn) } } }
    /// Presentational mixed state (`data-mixed`): input-colored track, thumb centered at 70%.
    public var isMixed = false { didSet { if isMixed != oldValue { apply(animated: true) } } }
    public final var onChange: (@MainActor (Bool) -> Void)?

    private let ring = BoxDecorationLayer()
    private let track = CALayer()
    private let thumbSlide = CALayer()     // carries the translate
    private let thumbStretch = CALayer()   // carries the press scale
    private let thumb = BoxDecorationLayer()

    public convenience init(isOn: Bool = false, size: Size = .default) {
        self.init(frame: .zero)
        self.size = size
        self.isOn = isOn
        apply(animated: false)
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scalesWhenPressed = false
        ring.host = self
        thumb.host = self
        for l in [track, thumbSlide, thumbStretch] {
            l.actions = ["position": NSNull(), "bounds": NSNull(), "transform": NSNull(), "backgroundColor": NSNull(),
                         "opacity": NSNull(), "anchorPoint": NSNull(), "cornerRadius": NSNull()]
        }
        ring.actions = ["opacity": NSNull()]
        thumbSlide.anchorPoint = .zero
        layer?.addSublayer(ring)
        layer?.addSublayer(track)
        layer?.addSublayer(thumbSlide)
        thumbSlide.addSublayer(thumbStretch)
        thumbStretch.addSublayer(thumb)
        layer?.masksToBounds = false
        setAccessibilityRole(.checkBox)
        setAccessibilitySubrole(.switch)
        apply(animated: false)
    }

    public override func performAction() {
        isOn.toggle()
        onChange?(isOn)
        super.performAction()
    }

    public override var intrinsicContentSize: NSSize {
        let t = size.thumb
        return NSSize(width: 2 * t - 2, height: t + 2)
    }

    public override func layout() {
        super.layout()
        ring.layout(boxSize: bounds.size)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.frame = bounds
        track.cornerRadius = bounds.height / 2
        let d = size.thumb - 2
        thumbSlide.bounds = CGRect(x: 0, y: 0, width: d, height: d)
        thumbSlide.position = CGPoint(x: 2, y: 2) // p-[2px]
        thumb.layout(boxSize: CGSize(width: d, height: d))
        CATransaction.commit()
        apply(animated: false)
    }

    public override func stateDidChange(from old: State) {
        super.stateDidChange(from: old)
        apply(animated: true)
    }

    public override func updateLayer() { apply(animated: false) }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        ring.setNeedsDisplay()
        thumb.setNeedsDisplay()
    }

    private func apply(animated: Bool) {
        let animate = animated && window != nil && !Motion.reduced
        let t = size.thumb, d = t - 2

        var ringStyle = BoxStyle()
        ringStyle.radius = 9999
        if state.focusVisible {
            ringStyle.shadows = BoxShadow.focusRing(ring: Themed.color(\.ring), offset: Themed.color(\.background))
        }
        ring.boxStyle = ringStyle

        var thumbStyle = BoxStyle()
        thumbStyle.radius = 9999
        thumbStyle.fill = Themed.color(\.background)
        thumbStyle.shadows = [BoxShadow(y: 1, blur: 3, color: Themed.black(0.05)),
                              BoxShadow(y: 1, blur: 2, spread: -1, color: Themed.black(0.05))]
        thumb.boxStyle = thumbStyle

        let trackColor = (isOn && !isMixed ? Themed.color(\.primary) : Themed.color(\.contrastInput)).cgColor(in: self)
        let offset = isMixed ? (t - 4) / 2 : (isOn ? t - 4 : 0)
        let slide = CATransform3DMakeTranslation(offset, 0, 0)
        let stretched = state.active && state.enabled
        let stretch = CATransform3DMakeScale(stretched ? 1.1 : 1, 1, 1)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if animate {
            Motion.animate(track, keyPath: "backgroundColor", to: trackColor, duration: 0.2)
            if !CATransform3DEqualToTransform(thumbSlide.transform, slide) {
                Motion.animate(thumbSlide, keyPath: "transform", to: NSValue(caTransform3D: slide), duration: 0.15,
                               timing: CAMediaTimingFunction(name: .default)) // CSS `ease`
            }
            if !CATransform3DEqualToTransform(thumbStretch.transform, stretch) {
                let a = CABasicAnimation(keyPath: "transform")
                a.fromValue = thumbStretch.presentation()?.transform ?? thumbStretch.transform
                a.toValue = NSValue(caTransform3D: stretch)
                a.beginTime = CACurrentMediaTime() + 0.1 // `scale .1s .1s`
                a.duration = 0.1
                a.fillMode = .backwards
                a.timingFunction = CAMediaTimingFunction(name: .default)
                thumbStretch.add(a, forKey: "transform")
            }
        }
        track.backgroundColor = trackColor
        thumbSlide.transform = slide
        thumbSlide.opacity = isMixed ? 0.7 : 1
        // `origin-left`, `data-checked:origin-right`: anchor the stretch on the resting side.
        thumbStretch.anchorPoint = CGPoint(x: isOn ? 1 : 0, y: 0.5)
        thumbStretch.bounds = CGRect(x: 0, y: 0, width: d, height: d)
        thumbStretch.position = CGPoint(x: isOn ? d : 0, y: d / 2)
        thumbStretch.transform = stretch
        CATransaction.commit()
    }
}
