import AppKit
import DesignSystem

/// The round primary action (ComposerPrimaryActions.tsx:134-159, 310-355): 32px, send in
/// `message-action` blue or the Nightly stage art, Stop in `destructive/90`, and the queue,
/// steer, resume, update (edited queued message) and busy faces. Hover scales to 1.05 over 150ms; there is no press scale.
/// J-composer-visuals section 4.
final class ComposerPrimaryButton: ControlView {
    static let size: CGFloat = 32

    var face: ComposerLogic.PrimaryAction = .send { didSet { if face != oldValue { restyleFace() } } }
    /// Nightly and dev servers fill the send button with stage art; ours is the teddy from the sidebar's candy art.
    var stageArt = true { didSet { restyleFace() } }
    var tooltip: String = "" {
        didSet {
            tip.text = tooltip
            setAccessibilityLabel(tooltip)
        }
    }

    private let fill = CALayer()
    private let art = StageBackdropView()
    /// `inset-shadow-control-highlight`: `inset 0 1px white/16%`, a crescent along the top edge.
    private let highlight = CAShapeLayer()
    private var icon: NSView?
    private let spinner = SpinnerView(size: .sm)
    private lazy var tip = TooltipController.attach(to: self, text: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.size, height: Self.size))
        scalesWhenPressed = false
        let r = Self.size / 2
        layer?.cornerRadius = r
        fill.cornerRadius = r
        fill.masksToBounds = true
        layer?.addSublayer(fill)
        art.compact = true
        art.layer?.cornerRadius = r
        art.layer?.masksToBounds = true
        addSubview(art)
        let crescent = CGMutablePath()
        let box = CGRect(x: 0, y: 0, width: Self.size, height: Self.size)
        crescent.addEllipse(in: box)
        crescent.addEllipse(in: box.offsetBy(dx: 0, dy: 1))
        highlight.path = crescent
        highlight.fillRule = .evenOdd
        spinner.color = .white
        spinner.isHidden = true
        addSubview(spinner)
        restyleFace()
    }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.size, height: Self.size) }

    /// Dither (after Capy's desktop app): a rounded square in the action color with a dark glyph, no stage art.
    private var capy: Bool { ThemeRuntime.isDither(dark: effectiveAppearance.isDark) }
    static let capyRadius: CGFloat = DitherChrome.controlRadius

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyleFace()
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fill.frame = bounds
        highlight.frame = bounds
        // 32 normally, 28 as the question footer's Stop (`size-7`).
        let r = capy ? Self.capyRadius : bounds.height / 2
        if r > 0, layer?.cornerRadius != r {
            layer?.cornerRadius = r
            fill.cornerRadius = r
            art.layer?.cornerRadius = r
            let crescent = CGMutablePath()
            if capy {
                crescent.addPath(SmoothCorners.path(bounds, r, flipped: false))
                crescent.addPath(SmoothCorners.path(bounds.offsetBy(dx: 0, dy: 1), r, flipped: false))
            } else {
                crescent.addEllipse(in: bounds)
                crescent.addEllipse(in: bounds.offsetBy(dx: 0, dy: 1))
            }
            highlight.path = crescent
        }
        CATransaction.commit()
        art.frame = bounds
        if let icon {
            let s = icon.frame.size
            icon.frame.origin = CGPoint(x: (bounds.width - s.width) / 2, y: (bounds.height - s.height) / 2)
        }
        let s = spinner.intrinsicContentSize
        spinner.frame = NSRect(x: (bounds.width - s.width) / 2, y: (bounds.height - s.height) / 2, width: s.width, height: s.height)
    }

    private func restyleFace() {
        icon?.removeFromSuperview()
        icon = nil
        spinner.isHidden = face != .busy
        let white = capy && face != .stop ? Themed.color(\.primaryForeground) : NSColor.white
        let view: NSView? = switch face {
        case .send: IconView(definition: Self.arrowUp, size: 14, color: white)
        case .stop: IconView(definition: Self.stopSquare, size: 12, color: white)
        case .queue: IconView(name: .listPlus, size: 16, strokeColor: white)
        case .steer: IconView(name: .cornerUpRight, size: 16, strokeColor: white)
        case .resume: IconView(name: .play, size: 16, strokeColor: white, fillColor: white)
        case .update: IconView(name: .check, size: 16, strokeColor: white)
        case .busy: nil
        }
        if let view { addSubview(view); icon = view }
        art.isHidden = !stageArt || face == .stop || capy
        needsLayout = true
        restyle()
    }

    override func stateDidChange(from old: State) {
        super.stateDidChange(from: old)
        if old.hovered != state.hovered { animateHover() }
        restyle()
    }

    private func restyle() { needsDisplay = true }

    override func updateLayer() {
        let enabled = state.enabled
        let modern = ComposerDesign.uses3814(dark: effectiveAppearance.isDark)
        disabledOpacity = modern && !stageArt ? 1 : 0.64
        alphaValue = enabled ? 1 : CGFloat(disabledOpacity)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let shadowColor: NSColor
        if face == .stop {
            fill.backgroundColor = Themed.color(\.destructive, state.hovered ? 1 : 0.9).cgColor(in: self)
            shadowColor = Themed.color(\.destructive)
        } else if capy {
            fill.backgroundColor = Themed.color(\.primary, state.hovered ? 0.9 : 1).cgColor(in: self)
            shadowColor = Themed.color(\.primary)
        } else if stageArt {
            fill.backgroundColor = nil
            shadowColor = .black
        } else if modern && !enabled {
            fill.backgroundColor = Themed.color(\.foreground, 0.12).cgColor(in: self)
            (icon as? IconView)?.strokeColor = Themed.color(\.mutedForeground)
            shadowColor = Themed.color(\.messageAction)
        } else {
            (icon as? IconView)?.strokeColor = .white
            fill.backgroundColor = Themed.color(state.hovered ? \.messageActionHover : \.messageAction).cgColor(in: self)
            shadowColor = Themed.color(\.messageAction)
        }
        // `shadow-xs` (0 1px 2px) at 24% of the fill color; none while disabled or held.
        let shadowed = enabled && !state.active
        layer?.shadowColor = shadowColor.cgColor(in: self)
        layer?.shadowOpacity = shadowed ? 0.24 : 0
        layer?.shadowRadius = 1
        layer?.shadowOffset = CGSize(width: 0, height: -1)
        layer?.shadowPath = capy ? SmoothCorners.path(bounds, Self.capyRadius, flipped: false)
            : CGPath(ellipseIn: bounds, transform: nil)
        // Enabled: the white top highlight; held: `inset 0 1px black/8%`.
        highlight.fillColor = state.active ? Themed.black(0.08).cgColor : Themed.white(0.16).cgColor
        if enabled { if highlight.superlayer == nil { layer?.addSublayer(highlight) } } else { highlight.removeFromSuperlayer() }
        highlight.zPosition = 1
        // The white glyph gets a soft plum halo over the teddy art, whose light end is pale pink.
        if let iconLayer = icon?.layer {
            iconLayer.shadowColor = CGColor(srgbRed: 34 / 255, green: 16 / 255, blue: 58 / 255, alpha: 1)
            iconLayer.shadowOpacity = art.isHidden ? 0 : 0.6
            iconLayer.shadowRadius = 1
            iconLayer.shadowOffset = .zero
        }
        CATransaction.commit()
    }

    private func animateHover() {
        guard let layer else { return }
        let s: CGFloat = state.hovered && state.enabled ? 1.05 : 1
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        var t = CATransform3DMakeTranslation(c.x, c.y, 0)
        t = CATransform3DScale(t, s, s, 1)
        t = CATransform3DTranslate(t, -c.x, -c.y, 0)
        if !Motion.reduced {
            Motion.animate(layer, keyPath: "sublayerTransform", to: NSValue(caTransform3D: t), duration: Motion.Durations.default)
        }
        layer.sublayerTransform = t
    }

    /// T3's own send arrow: `M7 11.5V2.5M7 2.5L3 6.5M7 2.5L11 6.5`, stroke 1.8, round.
    static let arrowUp = IconDefinition(viewBox: IconViewBox(x: 0, y: 0, width: 14, height: 14), elements: [
        IconElement(.path(d: "M7 11.5V2.5M7 2.5L3 6.5M7 2.5L11 6.5"),
                    IconPaint(stroke: .current, strokeWidth: 1.8, lineCap: .round, lineJoin: .round)),
    ])

    /// The Stop glyph: a 8x8 square with 1.5 corners in a 12x12 box, filled.
    static let stopSquare = IconDefinition(viewBox: IconViewBox(x: 0, y: 0, width: 12, height: 12), elements: [
        IconElement(.rect(x: 2, y: 2, w: 8, h: 8, rx: 1.5, ry: 1.5), IconPaint(fill: .current)),
    ])
}
