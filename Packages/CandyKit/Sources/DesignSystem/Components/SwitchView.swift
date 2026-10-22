import AppKit
import QuartzCore

/// T3's `Switch` (`apps/web/src/components/ui/switch.tsx`), desktop values.
/// Spec: docs/research/recovered/ui-components-b.md section 3.
/// Motion as in T3: track color 200ms ease-in-out, thumb slide 150ms `ease`,
/// press stretch `scale-x-110` over 100ms after a 100ms delay, anchored on the side it rests on.
/// While pressed T3 also sets `rounded-[size/size*1.1]` (switch.tsx:38), so the stretched thumb keeps
/// round ends: a 10% wider pill. The thumb grows its width instead of scaling, which draws that pill;
/// `BoxDecorationLayer`'s 9-slice keeps the ends round while the width runs.
/// ponytail: T3 eases the radius over 150ms without the delay, a 0.6pt squarer circle for the first
/// 100ms that this skips; draw an elliptical radius if anyone sees it
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
    private let thumbStretch = CALayer()   // the thumb's resting box; the thumb widens inside it when pressed
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
        layer?.addSublayer(track)
        // Over the track: the ring is inset (3473 switch.tsx:14, `focus-visible:ring-inset`), under the thumb.
        layer?.addSublayer(ring)
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

    /// Redesign's switch in dark, measured on Capy's settings page (2x, converted from Display P3 to sRGB): a 30 by 18
    /// track, a 14pt knob inset 2pt, the knob solid `--panel` #131314 with no shadow. The on track is the accent
    /// (#2b948b for teal), the off track Capy's `--muted` #353537.
    static let ditherDarkKnob = NSColor(srgbRed: 0x13 / 255, green: 0x13 / 255, blue: 0x14 / 255, alpha: 1)
    static let ditherDarkOffTrack = NSColor(srgbRed: 0x35 / 255, green: 0x35 / 255, blue: 0x37 / 255, alpha: 1)

    private func apply(animated: Bool) {
        let animate = animated && window != nil && !Motion.reduced
        let t = size.thumb, d = t - 2

        var ringStyle = BoxStyle()
        ringStyle.radius = 9999
        if state.focusVisible {
            ringStyle.shadows = BoxShadow.focusRing(ring: Themed.color(\.ring), offset: Themed.color(\.background)).map { s in
                var s = s
                s.inset = true
                return s
            }
        }
        ring.boxStyle = ringStyle

        var thumbStyle = BoxStyle()
        thumbStyle.radius = 9999
        // `dark:data-unchecked:bg-muted-foreground` keeps an off switch visible in dark (3473 switch.tsx:36, 8a948076bb).
        let dark = effectiveAppearance.isDark
        let ditherDark = dark && ThemeRuntime.isDither(dark: true)
        if ditherDark {
            // Redesign in dark: a solid knob, crisp, the same in both states. The card color is a frosted pane, so not that.
            thumbStyle.fill = Self.ditherDarkKnob
        } else {
            let dither = ThemeRuntime.isDither(dark: dark)
            thumbStyle.fill = isOn ? (dither ? .white : Themed.color(\.background)) : Themed.color(light: \.background, dark: \.contrastMutedForeground)
            thumbStyle.shadows = [BoxShadow(y: 1, blur: 3, color: Themed.black(0.05)),
                                  BoxShadow(y: 1, blur: 2, spread: -1, color: Themed.black(0.05))]
        }
        thumb.boxStyle = thumbStyle

        let onColor = ditherDark ? ThemeRuntime.ditherAccent.darkColor : Themed.color(\.primary)
        let offColor = ditherDark ? Self.ditherDarkOffTrack : Themed.color(\.contrastInput)
        let trackColor = (isOn && !isMixed ? onColor : offColor).cgColor(in: self)
        let offset = isMixed ? (t - 4) / 2 : (isOn ? t - 4 : 0)
        let slide = CATransform3DMakeTranslation(offset, 0, 0)
        let stretched = state.active && state.enabled
        // `scale-x-110` from the resting side (`origin-left`, `data-checked:origin-right`).
        let width = stretched ? d * 1.1 : d
        let o = thumb.outset
        let thumbFrame = CGRect(x: (isOn ? d - width : 0) - o, y: -o, width: width + 2 * o, height: d + 2 * o)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if animate {
            Motion.animate(track, keyPath: "backgroundColor", to: trackColor, duration: 0.2)
            if !CATransform3DEqualToTransform(thumbSlide.transform, slide) {
                Motion.animate(thumbSlide, keyPath: "transform", to: NSValue(caTransform3D: slide), duration: 0.15,
                               timing: CAMediaTimingFunction(name: .default)) // CSS `ease`
            }
            if thumb.frame != thumbFrame {
                let now = thumb.presentation() ?? thumb
                for (key, from, to) in [("bounds", NSValue(rect: now.bounds), NSValue(rect: CGRect(origin: .zero, size: thumbFrame.size))),
                                        ("position", NSValue(point: now.position),
                                         NSValue(point: CGPoint(x: thumbFrame.midX, y: thumbFrame.midY)))] {
                    let a = CABasicAnimation(keyPath: key)
                    a.fromValue = from
                    a.toValue = to
                    a.beginTime = CACurrentMediaTime() + 0.1 // `scale .1s .1s`
                    a.duration = 0.1
                    a.fillMode = .backwards
                    a.timingFunction = CAMediaTimingFunction(name: .default)
                    thumb.add(a, forKey: key)
                }
            }
        }
        track.backgroundColor = trackColor
        thumbSlide.transform = slide
        thumbSlide.opacity = isMixed ? 0.7 : 1
        // `origin-left`, `data-checked:origin-right`: anchor the stretch on the resting side.
        thumbStretch.anchorPoint = CGPoint(x: isOn ? 1 : 0, y: 0.5)
        thumbStretch.bounds = CGRect(x: 0, y: 0, width: d, height: d)
        thumbStretch.position = CGPoint(x: isOn ? d : 0, y: d / 2)
        thumb.frame = thumbFrame
        CATransaction.commit()
    }
}
