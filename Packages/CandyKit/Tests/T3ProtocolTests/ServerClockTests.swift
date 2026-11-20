import Foundation
import Testing
@testable import T3Protocol

/// 4928 client-runtime clock.test.ts (#36420): live timers count on the host's clock.
@Suite(.serialized) struct ServerClockTests {
    @Test func keepsTheOffsetNearestZeroWithinTheRequestWindow() {
        defer { ServerClock.reset() }
        // The host stamped inside the window: clocks agree, latency doesn't shift timers.
        ServerClock.record(environmentId: "a", serverTimeMs: 1_050, requestedAtMs: 1_000, receivedAtMs: 1_100)
        #expect(ServerClock.toServerClock("a", 5_000) == 5_000)
        // Ahead of the reply: the host runs 60s fast.
        ServerClock.record(environmentId: "b", serverTimeMs: 61_100, requestedAtMs: 1_000, receivedAtMs: 1_100)
        #expect(ServerClock.toServerClock("b", 5_000) == 65_000)
        // Behind the request: the host runs 30s slow.
        ServerClock.record(environmentId: "c", serverTimeMs: 1_000 - 30_000, requestedAtMs: 1_000, receivedAtMs: 1_100)
        #expect(ServerClock.toServerClock("c", 5_000) == 5_000 - 30_000)
        // A host without serverTime forgets the earlier reading; unknown and unscoped ids read this Mac's clock.
        ServerClock.record(environmentId: "b", serverTimeMs: nil, requestedAtMs: 0, receivedAtMs: 0)
        #expect(ServerClock.toServerClock("b", 5_000) == 5_000)
        #expect(ServerClock.toServerClock(nil, 5_000) == 5_000)
    }

    @Test func configDecodesServerTime() throws {
        let config = try JSONDecoder().decode(ServerProviderConfig.self, from: Data(#"{"providers":[],"serverTime":"2026-11-19T10:00:00.000Z"}"#.utf8))
        #expect(config.serverTime?.epochMs == T3Timestamp.parseEpochMs("2026-11-19T10:00:00.000Z"))
        let old = try JSONDecoder().decode(ServerProviderConfig.self, from: Data(#"{"providers":[]}"#.utf8))
        #expect(old.serverTime == nil)
    }
}
