import AppKit
import QuartzCore

/// A panel's open fraction, 0 closed to 1 open, moving the way T3's panel CSS transitions move `left` and
/// `width`: `ease-out` over `panelAnimationDurationMs`, one step per display frame. The host lays its views
/// out from `value` in `onFrame`, so whatever takes the panel's room (the main panel) reflows every frame,
/// as it does in the browser. A new target mid-slide starts from where the panel is and takes the share of
/// the duration it has left to travel, like a reversed CSS transition. The display link exists only while a
/// slide runs. Used by `SidebarLayoutView`; any panel that slides in from an edge can drive its frames
/// with one.
@MainActor
public final class PanelSlide: NSObject {
    /// Where the panel is now. Equals the target when no slide runs.
    public private(set) var value: CGFloat
    public private(set) var target: CGFloat
    public var isRunning: Bool { link != nil }
    /// Called with the new value on every frame of a slide and once on a jump.
    public var onFrame: (CGFloat) -> Void = { _ in }
    /// Called once when the panel reaches its target, after the last `onFrame`.
    public var onEnd: () -> Void = {}

    private var from: CGFloat = 0
    private var start: CFTimeInterval = 0
    private var duration: CFTimeInterval = 0
    private var link: CADisplayLink?
    /// CSS `ease-out`.
    static let curve = CubicBezier(0, 0, 0.58, 1)

    public init(value: CGFloat) {
        self.value = value
        target = value
    }

    /// Slides to `target` over `duration` scaled by the distance left, on `view`'s display. Without a
    /// window or a duration it jumps.
    public func run(to target: CGFloat, duration: CFTimeInterval, in view: NSView) {
        guard duration > 0, view.window != nil, target != value else { return jump(to: target) }
        from = value
        self.target = target
        self.duration = duration * Double(abs(target - value))
        start = CACurrentMediaTime()
        if link == nil {
            let link = view.displayLink(target: self, selector: #selector(frameFired))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
    }

    /// Ends any slide at `target` at once.
    public func jump(to target: CGFloat) {
        link?.invalidate()
        link = nil
        self.target = target
        value = target
        onFrame(value)
        onEnd()
    }

    @objc private func frameFired(_ link: CADisplayLink) {
        guard Self.timing else { return step(at: link.targetTimestamp) }
        let begin = CACurrentMediaTime(), gap = lastFrame.map { link.timestamp - $0 } ?? 0
        lastFrame = link.timestamp
        step(at: link.targetTimestamp)
        if !isRunning { lastFrame = nil }
        FileHandle.standardError.write(Data(String(format: "slide frame %.1f ms after the last, %.2f ms of work, value %.3f\n",
                                                   gap * 1000, (CACurrentMediaTime() - begin) * 1000, value).utf8))
    }

    /// Development: with CANDY_SIDEBAR_TIMING set, every slide frame prints its gap and the time its layout took.
    private static let timing = ProcessInfo.processInfo.environment["CANDY_SIDEBAR_TIMING"] != nil
    private var lastFrame: CFTimeInterval?

    /// One frame for the moment `time` (media time). Tests call it to stop a slide midway.
    func step(at time: CFTimeInterval) {
        let t = duration > 0 ? min(1, max(0, (time - start) / duration)) : 1
        if t >= 1 { return jump(to: target) }
        value = from + (target - from) * CGFloat(Self.curve.y(atX: t))
        onFrame(value)
    }
}

/// A CSS `cubic-bezier(x1, y1, x2, y2)` timing curve: the progress at a time fraction.
struct CubicBezier {
    let cx, bx, ax, cy, by, ay: Double

    init(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
        cx = 3 * x1; bx = 3 * (x2 - x1) - cx; ax = 1 - cx - bx
        cy = 3 * y1; by = 3 * (y2 - y1) - cy; ay = 1 - cy - by
    }

    func y(atX x: Double) -> Double {
        let s = solve(x)
        return ((ay * s + by) * s + cy) * s
    }

    /// The curve parameter whose x is `x`: Newton's method, then bisection when the slope is flat.
    private func solve(_ x: Double) -> Double {
        func sampleX(_ s: Double) -> Double { ((ax * s + bx) * s + cx) * s }
        var s = x
        for _ in 0..<8 {
            let err = sampleX(s) - x
            if abs(err) < 1e-7 { return s }
            let slope = (3 * ax * s + 2 * bx) * s + cx
            if abs(slope) < 1e-6 { break }
            s -= err / slope
        }
        var lo = 0.0, hi = 1.0
        s = x
        while lo < hi {
            let v = sampleX(s)
            if abs(v - x) < 1e-7 { return s }
            if x > v { lo = s } else { hi = s }
            s = (lo + hi) / 2
            if hi - lo < 1e-9 { break }
        }
        return s
    }
}
