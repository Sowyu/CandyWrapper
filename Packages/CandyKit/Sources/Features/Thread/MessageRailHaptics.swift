import AppKit
import DesignSystem

/// How the message rail taps the trackpad as the pointer moves along it: one tap for each message line the pointer
/// crosses, like a dial's detents. `NSHapticFeedbackManager` has no strength setting, only three patterns, so a level
/// is a pattern. Apple documents no strength order between them. The user found 1.16.0's `.alignment` per message (now
/// `strong`) "a bit strong", so `light` is the default and plays `.generic`. 1.17.0 thinned the taps instead, and the
/// user missed "a slight light haptic on every line". Settings > General > Input > Message rail ticks picks one.
public enum MessageRailHaptic: String, CaseIterable, Sendable {
    case off, light, medium, strong

    /// Where the app reads the level from: the `messageRailHaptic` client setting.
    @MainActor public static var current: () -> MessageRailHaptic = { .light }

    var pattern: NSHapticFeedbackManager.FeedbackPattern? {
        switch self {
        case .off: nil
        case .light: .generic
        case .medium: .levelChange
        case .strong: .alignment // 1.16.0
        }
    }

    /// The rail's line pitch is at most 8pt (`TimelineView.layoutMinimap`), so a 300pt a second sweep over the shortest
    /// rail crosses about 37 lines a second. 40 keeps every tap of that and stops a flick over a long rail, where lines
    /// sit 2 to 3pt apart, from buzzing.
    // ponytail: one cap tuned without a finger on a trackpad; tie it to the pitch if long threads drop taps on slow sweeps
    static let perSecond: Double = 40
}

/// Decides which hover moves along the rail tap. Holds one timestamp and runs only on a move.
struct MessageRailHapticPacer {
    private var lastTap: TimeInterval = -.infinity

    /// The pattern to play for a hover move from tick `old` to `new` of `count`. A jump over several lines is one tap.
    mutating func pattern(_ level: MessageRailHaptic, from old: Int, to new: Int, count: Int, at t: TimeInterval)
        -> NSHapticFeedbackManager.FeedbackPattern? {
        guard let pattern = level.pattern, old != new, count > 1 else { return nil }
        guard t - lastTap >= 1 / MessageRailHaptic.perSecond - 0.001 else { return nil }
        lastTap = t
        return pattern
    }
}
