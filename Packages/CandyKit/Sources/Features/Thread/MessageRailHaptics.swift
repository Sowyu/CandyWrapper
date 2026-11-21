import AppKit
import DesignSystem

/// How hard the message rail taps the trackpad as the pointer moves along it. `NSHapticFeedbackManager` has no
/// strength setting, only three patterns, so a level is a pattern, a rate cap, how many taps a full sweep gives and
/// a speed above which a sweep is silent. The user felt 1.16.0's tap per message (now `strong`) and said "its a bit
/// strong", so `light` is the default. Settings > General > Input > Message rail ticks picks one.
public enum MessageRailHaptic: String, CaseIterable, Sendable {
    case off, light, medium, strong

    /// Where the app reads the level from: the `messageRailHaptic` client setting.
    @MainActor public static var current: () -> MessageRailHaptic = { .light }

    struct Feel: Equatable {
        var pattern: NSHapticFeedbackManager.FeedbackPattern
        var perSecond: Double
        /// About this many taps from one end of the rail to the other, whatever the thread's length; nil taps every message.
        var perSweep: Int?
        /// A pointer faster than this, in points a second, is crossing the rail rather than reading it, and taps nothing.
        var maxSpeed: CGFloat?
    }

    /// The four levels in one place.
    var feel: Feel? {
        switch self {
        case .off: nil
        case .light: Feel(pattern: .generic, perSecond: 6, perSweep: 10, maxSpeed: 400)
        case .medium: Feel(pattern: .generic, perSecond: 8, perSweep: 16, maxSpeed: 800)
        case .strong: Feel(pattern: .alignment, perSecond: 12, perSweep: nil, maxSpeed: nil) // 1.16.0
        }
    }
}

/// Decides which hover moves along the rail tap. Holds a timestamp and the pointer's last sample, and runs only on a move.
struct MessageRailHapticPacer {
    private var lastTap: TimeInterval = -.infinity
    private var lastSample: (y: CGFloat, t: TimeInterval)?

    /// Records the pointer at `y` at time `t` and returns its speed in points a second since the last sample.
    mutating func sample(y: CGFloat, at t: TimeInterval) -> CGFloat {
        defer { lastSample = (y, t) }
        guard let s = lastSample, t > s.t else { return 0 }
        return abs(y - s.y) / CGFloat(max(0.001, t - s.t))
    }

    /// Forgets the last sample, so the first move after the pointer comes back measures no speed from before.
    mutating func reset() { lastSample = nil }

    /// The pattern to play for a hover move from tick `old` to `new` of `count`, at `speed` (0 for a key).
    mutating func pattern(_ level: MessageRailHaptic, from old: Int, to new: Int, count: Int, speed: CGFloat, at t: TimeInterval)
        -> NSHapticFeedbackManager.FeedbackPattern? {
        guard let feel = level.feel, old != new, count > 1 else { return nil }
        if let max = feel.maxSpeed, speed > max { return nil }
        let stride = feel.perSweep.map { Swift.max(1, Int((Double(count) / Double($0)).rounded(.up))) } ?? 1
        guard old / stride != new / stride else { return nil }
        guard t - lastTap >= 1 / feel.perSecond - 0.001 else { return nil }
        lastTap = t
        return feel.pattern
    }
}
