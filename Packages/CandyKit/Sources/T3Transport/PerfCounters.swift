import Foundation
import T3Protocol

/// Counts server messages for the performance HUD. Counting is off until the HUD turns it on, so
/// a hidden HUD costs one uncontended lock per received frame and nothing else.
public enum PerfCounters {
    private static let state = NSLockedBox((on: false, events: 0))

    /// Every server message a socket decoded (replies, stream chunks, pushes).
    public static func received(_ count: Int) {
        state.with { if $0.on { $0.events += count } }
    }

    /// Turns counting on or off and clears the count.
    public static func setCounting(_ on: Bool) {
        state.with { $0 = (on, 0) }
    }

    /// The messages since the last call, then starts again from zero.
    public static func takeEvents() -> Int {
        state.with { s in
            defer { s.events = 0 }
            return s.events
        }
    }
}
