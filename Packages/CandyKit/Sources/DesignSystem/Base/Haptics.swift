import AppKit

/// Force Touch trackpad taps for detents: a rail tick, a divider limit, a zoom level, a drop slot. macOS plays them
/// only on a Force Touch trackpad the finger is on, and only when System Settings allows it. On top of that a tap
/// needs the app's Trackpad haptics setting, a pointer or key event in progress (never a scroll or a model change),
/// and a gap since the last tap. Nothing runs between taps: the rate limit compares two timestamps.
@MainActor
public enum Haptics {
    public typealias Pattern = NSHapticFeedbackManager.FeedbackPattern

    /// Settings > General > Trackpad haptics; the app points this at its client settings.
    public static var isEnabled: () -> Bool = { true }
    /// The system performer. Tests swap in a recorder.
    public static var perform: (Pattern) -> Void = { pattern in
        #if DEBUG
        // `CANDY_HAPTICS_LOG=1` logs each tap, since no agent can feel one.
        if ProcessInfo.processInfo.environment["CANDY_HAPTICS_LOG"] != nil { NSLog("haptic %ld", pattern.rawValue) }
        #endif
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }
    public static var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// The event being handled and the mouse buttons held. Tests swap in their own.
    public static var currentEvent: () -> (type: NSEvent.EventType?, buttons: Int) = {
        (NSApp?.currentEvent?.type, NSEvent.pressedMouseButtons)
    }
    /// At most 12 taps a second, so a fast sweep over the rail ratchets instead of buzzing.
    // ponytail: one global interval tuned without a finger on a trackpad; give patterns their own if a drop tap gets eaten
    public static var minimumInterval: TimeInterval = 1.0 / 12
    static var last: TimeInterval = -.infinity

    /// Plays `pattern` if the setting, the event and the rate limit allow it. Returns whether it played.
    @discardableResult
    public static func tap(_ pattern: Pattern = .alignment) -> Bool {
        guard isEnabled(), isInteraction(currentEvent()) else { return false }
        let t = now()
        // A millisecond of slack, so events that arrive exactly one interval apart all play.
        guard t - last >= minimumInterval - 0.001 else { return false }
        last = t
        perform(pattern)
        return true
    }

    /// A pointer move, drag, press, pinch or key, or any event while a button is held. A scroll is the system's, and
    /// no event means a model or timer changed the value.
    static func isInteraction(_ context: (type: NSEvent.EventType?, buttons: Int)) -> Bool {
        guard let type = context.type, type != .scrollWheel else { return false }
        if context.buttons != 0 { return true }
        switch type {
        case .mouseMoved, .mouseEntered, .mouseExited, .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDragged,
             .otherMouseDragged, .magnify, .smartMagnify, .gesture, .beginGesture, .endGesture, .pressure, .keyDown:
            return true
        default:
            return false
        }
    }

    /// Whether moving from `old` to `new` lands on or passes one of `detents`: a limit reached, or a level crossed.
    public static func crosses(from old: CGFloat, to new: CGFloat, _ detents: [CGFloat]) -> Bool {
        guard old != new else { return false }
        return detents.contains { d in new == d || (old < d) != (new < d) && old != d }
    }

    /// For tests: records the taps `body` makes instead of playing them, as if handling `event` with no rate limit.
    static func recording(_ event: NSEvent.EventType? = .leftMouseDragged, buttons: Int = 0,
                          _ body: () throws -> Void) rethrows -> [Pattern] {
        let saved = (isEnabled, perform, currentEvent, minimumInterval, last)
        defer { (isEnabled, perform, currentEvent, minimumInterval, last) = saved }
        var taps: [Pattern] = []
        isEnabled = { true }; perform = { taps.append($0) }; currentEvent = { (event, buttons) }; minimumInterval = 0; last = -.infinity
        try body()
        return taps
    }
}
