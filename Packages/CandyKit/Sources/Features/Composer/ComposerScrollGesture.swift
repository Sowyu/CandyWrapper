import AppKit

/// composerScrollGesture.ts:39-95. The next event expires a gesture, so idle costs nothing.
public struct ComposerScrollGesture {
    private var accumulated: CGFloat = 0
    private var lastEvent = -Double.infinity
    private var suppressed = false
    public init() {}
    public mutating func suppress(now: Double) {
        if now - lastEvent <= 0.12 { suppressed = true }
    }
    public mutating func record(now: Double, delta: CGFloat, eligible: Bool, canScroll: Bool, towardEnd: Bool) -> Bool {
        if now - lastEvent > 0.12 { accumulated = 0; suppressed = false }
        lastEvent = now
        guard !suppressed, eligible, canScroll, !towardEnd else { accumulated = 0; return false }
        accumulated += abs(delta)
        guard accumulated >= 24 else { return false }
        accumulated = 0
        return true
    }
}

/// Delivers genuine timeline wheel gestures, never programmatic scrolls or editor scrolls.
final class ComposerTimelineScrollView: NSScrollView {
    var onGesture: ((CGFloat, Bool, Bool) -> Void)?
    override func scrollWheel(with event: NSEvent) {
        if !event.modifierFlags.contains(.control) {
            let y = contentView.bounds.minY
            let maxY = max(0, (documentView?.bounds.height ?? 0) - contentView.bounds.height)
            let delta = -event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 16)
            onGesture?(delta, delta < 0 ? y > 0 : y < maxY, delta > 0 && y >= maxY - 1)
        }
        super.scrollWheel(with: event)
    }
}
