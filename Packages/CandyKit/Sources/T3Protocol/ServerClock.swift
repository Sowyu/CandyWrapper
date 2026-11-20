import Foundation

/// How far each environment's clock runs ahead of this Mac's (4928 client-runtime clock.ts, #36420). Live working
/// timers count against host timestamps, so a host whose clock is off by a minute would otherwise show a minute too
/// many or too few. Timers read the offset on every tick, so a reconnect's new reading lands without a rebuild.
public enum ServerClock {
    private static let offsets = PortableLock<[String: Int64]>(initialState: [:])

    /// `recordServerClock`: the host stamped `serverTimeMs` between the request and its reply, so the offset lies within
    /// that window. The one nearest 0 is kept, so clocks that agree read as 0 instead of shifting every timer by the
    /// network's latency. A missing reading forgets the environment's offset.
    public static func record(environmentId: String, serverTimeMs: Int64?, requestedAtMs: Int64, receivedAtMs: Int64) {
        offsets.withLock { map in
            guard let server = serverTimeMs else { map[environmentId] = nil; return }
            map[environmentId] = server > receivedAtMs ? server - receivedAtMs : server < requestedAtMs ? server - requestedAtMs : 0
        }
    }

    /// `toServerClock`: client epoch milliseconds on the environment's clock. An unscoped or unknown environment reads 0.
    public static func toServerClock(_ environmentId: String?, _ clientMs: Int64) -> Int64 {
        guard let environmentId else { return clientMs }
        return clientMs + (offsets.withLock { $0[environmentId] } ?? 0)
    }

    /// Forgets every reading (tests).
    public static func reset() { offsets.withLock { $0 = [:] } }
}
