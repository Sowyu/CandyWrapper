import AppKit
import DesignSystem

/// What a bot's face says (docs/orchestrator.md, "The bots"): gaze and colour, never a mouth.
public enum BotMood: Equatable, Sendable {
    case idle, working, needsYou, unread(Int), blocked, archived

    var restingGaze: BotGaze? {
        switch self {
        case .needsYou: BotGaze(yaw: 0, pitch: 0.5)
        case .blocked, .archived: BotGaze(yaw: 0, pitch: -0.45)
        default: nil
        }
    }
}

/// One bot, drawn in Core Animation layers with no images. A new pose springs from where the face is now; a state
/// change plays one short flourish and stops. Nothing animates while nothing changes, and Reduce Motion sets each pose
/// without moving.
public final class BotView: NSView {
    public var identity: BotIdentity { didSet { if identity != oldValue { recolor(); redraw(animated: false) } } }
    public var mood: BotMood = .idle { didSet { if mood != oldValue { moodChanged(from: oldValue) } } }
    /// Set by the pointer while it moves over the bots, nil once it leaves.
    public private(set) var pointerGaze: BotGaze?

    private let body = CAShapeLayer()
    private let stem = CAShapeLayer()
    private let eyes = CAShapeLayer()
    private let badge = CATextLayer()
    private let badgeFill = CALayer()
    private var shown: BotGaze?

    public init(identity: BotIdentity, size: CGFloat = 20) {
        self.identity = identity
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        wantsLayer = true
        layer?.masksToBounds = false
        for l in [body, stem, eyes] as [CAShapeLayer] {
            l.actions = ["path": NSNull(), "fillColor": NSNull(), "strokeColor": NSNull(), "position": NSNull(), "bounds": NSNull()]
            l.lineJoin = .round
            l.lineCap = .round
            layer?.addSublayer(l)
        }
        badgeFill.actions = ["position": NSNull(), "bounds": NSNull(), "backgroundColor": NSNull(), "hidden": NSNull()]
        badge.actions = badgeFill.actions
        badge.alignmentMode = .center
        badgeFill.addSublayer(badge)
        layer?.addSublayer(badgeFill)
        badgeFill.isHidden = true
        recolor()
        BotGazeTracker.shared.register(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override var isFlipped: Bool { false }
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }
    public override var intrinsicContentSize: NSSize { frame.size }

    /// Each bot looks slightly off centre at rest, its own way.
    var restingGaze: BotGaze {
        if let g = mood.restingGaze { return g }
        let h = UInt32(truncatingIfNeeded: identity.shape.rawValue &* 31 &+ identity.color.rawValue &* 17)
        return BotGaze(yaw: (Double(h % 7) - 3) * 0.05, pitch: (Double(h % 5) - 2) * 0.03)
    }

    var gaze: BotGaze { pointerGaze ?? restingGaze }

    public override func layout() {
        super.layout()
        for l in [body, stem, eyes] { l.frame = bounds }
        redraw(animated: false)
        layoutBadge()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        recolor()
    }

    private func recolor() {
        let c = mood == .archived ? BotColor.grey.rgb : identity.color.rgb
        let fill = CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: mood == .archived ? 0.7 : 1)
        body.fillColor = fill
        body.strokeColor = fill
        stem.fillColor = CGColor(srgbRed: 0.36, green: 0.47, blue: 0.22, alpha: 1)
        stem.strokeColor = stem.fillColor
        eyes.fillColor = CGColor(srgbRed: 0.08, green: 0.08, blue: 0.09, alpha: 1)
    }

    /// Draws the current gaze; `animated` springs there from the face's present pose.
    private func redraw(animated: Bool) {
        let side = min(bounds.width, bounds.height)
        guard side > 0 else { return }
        let target = gaze
        let p = BotGeometry.paths(identity, gaze: target, size: side)
        let dx = (bounds.width - side) / 2, dy = (bounds.height - side) / 2
        var t = CGAffineTransform(translationX: dx, y: dy)
        let bodyPath = p.body.copy(using: &t), eyePath = p.eyes.copy(using: &t), stemPath = p.stem.flatMap { $0.copy(using: &t) }
        body.lineWidth = BotGeometry.lineWidth(identity, size: side)
        stem.lineWidth = side * 0.05
        let animate = animated && shown != nil && !Motion.reduced && window != nil
        if animate {
            spring(body, to: bodyPath)
            spring(eyes, to: eyePath)
            if let stemPath { spring(stem, to: stemPath) }
        }
        body.path = bodyPath
        eyes.path = eyePath
        stem.path = stemPath
        shown = target
    }

    private func spring(_ layer: CAShapeLayer, to path: CGPath?) {
        guard let from = layer.presentation()?.path ?? layer.path, let path else { return }
        let a = CASpringAnimation(keyPath: "path")
        a.fromValue = from
        a.toValue = path
        a.mass = 1
        a.stiffness = 220
        a.damping = 22
        a.duration = min(a.settlingDuration, 0.9)
        layer.add(a, forKey: "pose")
    }

    /// Points the eyes toward a spot in window coordinates, or back to rest with nil.
    func follow(windowPoint: NSPoint?) {
        let next: BotGaze? = windowPoint.map { w in
            let me = convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil)
            let dx = Double(w.x - me.x), dy = Double(w.y - me.y)
            // Close by the head turns fully; the reach eases off with distance.
            return BotGaze(yaw: atan(dx / 140) * 1.1, pitch: atan(dy / 140) * 0.9)
        }
        if let a = next, let b = pointerGaze, abs(a.yaw - b.yaw) + abs(a.pitch - b.pitch) < 0.04 { return }
        guard next != pointerGaze else { return }
        pointerGaze = next
        redraw(animated: true)
    }

    // MARK: State

    private func moodChanged(from old: BotMood) {
        recolor()
        layoutBadge()
        guard window != nil, !Motion.reduced else { redraw(animated: false); return }
        switch mood {
        case .working where old != .working: lookAround()
        case .needsYou where old != .needsYou: hop(); redraw(animated: true)
        default: redraw(animated: true)
        }
    }

    /// A slow one-shot look to each side, then back to rest.
    private func lookAround() {
        let side = min(bounds.width, bounds.height)
        guard side > 0 else { return }
        let shift = CGAffineTransform(translationX: (bounds.width - side) / 2, y: (bounds.height - side) / 2)
        let frames = [gaze, BotGaze(yaw: -0.55, pitch: 0.05), BotGaze(yaw: 0.55, pitch: 0.05), gaze]
            .map { BotGeometry.paths(identity, gaze: $0, size: side) }
        func moved(_ p: CGPath) -> CGPath { var t = shift; return p.copy(using: &t) ?? p }
        for (layer, values) in [(body, frames.map { moved($0.body) }), (eyes, frames.map { moved($0.eyes) })] {
            let a = CAKeyframeAnimation(keyPath: "path")
            a.values = values
            a.keyTimes = [0, 0.35, 0.7, 1]
            a.duration = 0.9
            a.timingFunctions = [Motion.easeInOut, Motion.easeInOut, Motion.easeInOut]
            layer.add(a, forKey: "pose")
        }
        redraw(animated: false)
    }

    /// A small hop, up and back down.
    private func hop() {
        let a = CAKeyframeAnimation(keyPath: "transform.translation.y")
        let h = bounds.height * 0.18
        a.values = [0, h, 0, h * 0.3, 0]
        a.keyTimes = [0, 0.3, 0.6, 0.8, 1]
        a.duration = 0.55
        a.isAdditive = true
        for s in [body, eyes, stem] { s.add(a, forKey: "hop") }
    }

    private func layoutBadge() {
        let text: String?
        let color: NSColor
        switch mood {
        case .needsYou: text = "!"; color = NSColor(srgbRed: 1, green: 0.72, blue: 0.16, alpha: 1)
        case .unread(let n) where n > 0: text = n > 9 ? "9+" : "\(n)"; color = NSColor(srgbRed: 0.27, green: 0.55, blue: 1, alpha: 1)
        default: text = nil; color = .clear
        }
        badgeFill.isHidden = text == nil
        guard let text else { return }
        let d = max(9, (bounds.height * 0.42).rounded())
        let w = max(d, CGFloat(text.count) * d * 0.55 + d * 0.4)
        badgeFill.frame = CGRect(x: bounds.width - w * 0.75, y: bounds.height - d * 0.8, width: w, height: d)
        badgeFill.cornerRadius = d / 2
        badgeFill.backgroundColor = color.cgColor
        badge.string = text
        badge.font = NSFont.systemFont(ofSize: d * 0.72, weight: .bold)
        badge.fontSize = d * 0.72
        badge.foregroundColor = mood == .needsYou ? NSColor.black.cgColor : NSColor.white.cgColor
        badge.contentsScale = window?.backingScaleFactor ?? 2
        badge.frame = CGRect(x: 0, y: (d - d * 0.86) / 2 - d * 0.04, width: w, height: d * 0.86)
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        badge.contentsScale = window?.backingScaleFactor ?? 2
        // A hidden or removed bot holds no animation.
        if window == nil { for l in [body, eyes, stem] { l.removeAllAnimations() }; pointerGaze = nil }
    }

    public override func viewDidHide() {
        super.viewDidHide()
        for l in [body, eyes, stem] { l.removeAllAnimations() }
    }
}

/// Lets the bots in one area follow the pointer: the area forwards its pointer moves, and every bot shown in that
/// window turns toward the pointer with a spring. It runs only on pointer events.
@MainActor
public final class BotGazeTracker {
    public static let shared = BotGazeTracker()
    private let bots = NSHashTable<BotView>.weakObjects()

    func register(_ bot: BotView) { bots.add(bot) }

    /// The pointer moved to `windowPoint` in `window`; nil sends the bots back to rest.
    public func pointer(_ windowPoint: NSPoint?, in window: NSWindow?) {
        for bot in bots.allObjects where bot.window === window && window != nil {
            if bot.isHiddenOrHasHiddenAncestor { continue }
            bot.follow(windowPoint: windowPoint)
        }
    }
}
