import Foundation
import Testing
@testable import T3Client
import T3Protocol

struct BackoffTests {
    @Test func ladderMatchesT3() {
        // ceiling = min(300 s, 1 s * 2^(n+1)); delay in [ceiling/2, ceiling].
        #expect(Backoff.delayMilliseconds(failureCount: 0, random: 0) == 1_000)
        #expect(Backoff.delayMilliseconds(failureCount: 0, random: 0.999_999) == 2_000)
        #expect(Backoff.delayMilliseconds(failureCount: 1, random: 0.5) == 3_000)
        #expect(Backoff.delayMilliseconds(failureCount: 7, random: 1) == 256_000)
        #expect(Backoff.delayMilliseconds(failureCount: 8, random: 0) == 150_000)
        #expect(Backoff.delayMilliseconds(failureCount: 8, random: 1) == 300_000)
        #expect(Backoff.delayMilliseconds(failureCount: 1_000, random: 1) == 300_000)
    }
}

/// Controllable clock, random source and connector for the supervisor.
final class Harness: @unchecked Sendable {
    enum Outcome { case fail(Error), succeed }

    // NSLock guards everything below.
    private let lock = NSLock()
    private var offset: Duration = .zero
    private var outcomes: [Outcome]
    private(set) var sleeps: [Duration] = []
    private(set) var sockets: [FakeSocket] = []
    private(set) var attempts = 0
    let base = ContinuousClock.now

    init(_ outcomes: [Outcome]) { self.outcomes = outcomes }

    func advance(_ d: Duration) { lock.withLock { offset += d } }
    var recordedSleeps: [Duration] { lock.withLock { sleeps } }
    var attemptCount: Int { lock.withLock { attempts } }
    var lastSocket: FakeSocket? { lock.withLock { sockets.last } }

    var dependencies: ConnectionSupervisor.Dependencies {
        .init(
            connect: { [self] in
                let outcome: Outcome = lock.withLock {
                    attempts += 1
                    return outcomes.isEmpty ? .fail(ConnectionFailure.transient("script done")) : outcomes.removeFirst()
                }
                switch outcome {
                case .fail(let e): throw e
                case .succeed:
                    let socket = FakeSocket()
                    lock.withLock { sockets.append(socket) }
                    let c = RPCConnection(socket: socket)
                    await c.start()
                    return c
                }
            },
            sleep: { [self] d in
                let more = lock.withLock { sleeps.append(d); return !outcomes.isEmpty }
                // Out of script: park the retry timer so the test can inspect the state.
                if !more { try await Task.sleep(for: .seconds(3600)) }
            },
            now: { [self] in base + lock.withLock { offset } },
            random: { 0.5 }
        )
    }
}

struct SupervisorTests {
    let transient = ConnectionFailure.transient("refused")

    /// `ShellSession.stop` right after `start`: its disconnect lands first, so the late connect must not open.
    @Test func connectAfterAStopLandsDoesNothing() async {
        let h = Harness([.succeed])
        let s = ConnectionSupervisor(dependencies: h.dependencies)
        await s.disconnect()
        await s.connect(unlessStopped: { true })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(h.attemptCount == 0)
        #expect(await s.state.phase == .available)
    }

    /// The stop lands between the flag check and the connect: the second check disconnects.
    @Test func aStopDuringConnectEndsDisconnected() async {
        let h = Harness([.succeed, .succeed])
        let s = ConnectionSupervisor(dependencies: h.dependencies)
        let checks = CallCounter()
        await s.connect(unlessStopped: { await checks.next() > 1 })
        #expect(await eventually { await s.state.phase == .available })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await s.currentConnection == nil)
        #expect(h.attemptCount <= 1)
    }

    @Test func transientFailuresClimbTheLadder() async {
        let h = Harness([.fail(transient), .fail(transient), .fail(transient), .fail(transient)])
        let s = ConnectionSupervisor(dependencies: h.dependencies)
        await s.connect()
        // Four scripted failures; the fourth retry timer parks because the script is done.
        #expect(await eventually { h.recordedSleeps.count == 4 })
        #expect(h.recordedSleeps == [1_500, 3_000, 6_000, 12_000].map { .milliseconds($0) })
        let state = await s.state
        #expect(state.phase == .backoff)
        #expect(state.status == .reconnecting)
        #expect(state.attempt == 5)
        await s.disconnect()
        #expect(await s.state.phase == .available)
    }

    @Test func stableSessionResetsTheLadderButAFlapDoesNot() async {
        let h = Harness([.fail(transient), .succeed, .succeed, .succeed])
        let s = ConnectionSupervisor(dependencies: h.dependencies)
        await s.connect()
        #expect(await eventually { await s.state.phase == .connected })
        #expect(h.recordedSleeps == [.milliseconds(1_500)])

        // Flap: closes at once, so the ladder keeps climbing (second failure).
        h.lastSocket?.close()
        #expect(await eventually { h.recordedSleeps.count == 2 })
        #expect(h.recordedSleeps.last == .milliseconds(3_000))
        #expect(await eventually { let st = await s.state; return st.generation == 2 && st.phase == .connected })

        // Stable: up for 30 s, then lost. The ladder restarts at the first rung.
        h.advance(.seconds(31))
        h.lastSocket?.close()
        #expect(await eventually { h.recordedSleeps.count == 3 })
        #expect(h.recordedSleeps.last == .milliseconds(1_500))
        #expect(await eventually { await s.state.generation == 3 })
        await s.disconnect()
    }

    @Test func blockedFailureWaitsForASignal() async {
        let h = Harness([.fail(EnvironmentHTTPError.status(401, nil)), .succeed])
        let s = ConnectionSupervisor(dependencies: h.dependencies)
        await s.connect()
        #expect(await eventually { await s.state.phase == .blocked(.authentication) })
        await settle()
        #expect(h.recordedSleeps.isEmpty && h.attemptCount == 1)
        #expect(await s.state.status == .error)
        await s.retryNow()
        #expect(await eventually { await s.state.phase == .connected })
        await s.disconnect()
    }

    @Test func offlineMakesNoAttemptsUntilThePathReturns() async {
        let h = Harness([.succeed])
        let s = ConnectionSupervisor(dependencies: h.dependencies)
        await s.networkChanged(online: false)
        await s.connect()
        await settle()
        #expect(await s.state.phase == .offline)
        #expect(h.attemptCount == 0)
        await s.networkChanged(online: true)
        #expect(await eventually { await s.state.phase == .connected })
        #expect(h.attemptCount == 1)
        await s.disconnect()
    }

    /// Another Wi-Fi while online: T3's "network-changed" quick probe (wakeups.ts:10-12, supervisor.ts:593).
    @Test func aNetworkPathChangeProbesTheLiveSession() async {
        let h = Harness([.succeed])
        let s = ConnectionSupervisor(dependencies: h.dependencies)
        await s.connect()
        #expect(await eventually { await s.state.phase == .connected })
        let socket = h.lastSocket!
        await s.networkPathChanged()
        #expect(await eventually { socket.sent.contains { if case .request(let r) = $0 { r.tag == "server.probe" } else { false } } })
        await s.disconnect()
    }

    @Test func failedProbeReconnectsWithoutWaiting() async {
        let h = Harness([.succeed, .succeed])
        let s = ConnectionSupervisor(dependencies: h.dependencies)
        await s.connect()
        #expect(await eventually { await s.state.phase == .connected })
        let first = h.lastSocket!
        await s.wakeup(.systemWake)
        // The fake server never answers server.probe; the 3 s quick probe times out.
        #expect(await eventually { first.sent.contains { if case .request(let r) = $0 { r.tag == "server.probe" } else { false } } })
        #expect(await eventually(seconds: 5) { h.recordedSleeps.count == 1 })
        #expect(first.isClosed)
        #expect(h.recordedSleeps == [.zero])
        #expect(await eventually { await s.state.generation == 2 })
        await s.disconnect()
    }

    @Test func durableSubscriptionResubscribesWithTheCallersCursor() async {
        let h = Harness([.succeed, .succeed])
        let s = ConnectionSupervisor(dependencies: h.dependencies)
        let cursor = Cursor()
        let events = EventLog()
        let sub = s.subscribe("orchestration.subscribeShell", payload: {
            let after = await cursor.value
            return after == 0 ? .object([:]) : .object(["afterSequence": .number(Double(after))])
        }, handler: { event in
            await events.append(event)
            if case .value(let v) = event, case .number(let n)? = v["sequence"] { await cursor.set(Int(n)) }
        })
        await s.connect()
        #expect(await eventually { h.lastSocket?.sent.count == 1 })
        let first = h.lastSocket!
        guard case .request(let r1) = first.sent[0] else { Issue.record("request"); return }
        #expect(r1.payload == .object([:]))
        first.deliver(.chunk(requestId: r1.id, values: [.object(["sequence": .number(7)])]))
        #expect(await eventually { first.sent.count == 2 })

        first.close()
        #expect(await eventually { await s.state.generation == 2 && h.lastSocket !== first && h.lastSocket?.sent.count == 1 })
        guard case .request(let r2) = h.lastSocket!.sent[0] else { Issue.record("request"); return }
        #expect(r2.tag == "orchestration.subscribeShell")
        #expect(r2.payload == .object(["afterSequence": .number(7)]))
        #expect(await events.count(where: { if case .subscribed = $0 { true } else { false } }) == 2)

        sub.cancel()
        let second = h.lastSocket!
        #expect(await eventually { second.sent.last == .interrupt(r2.id) })
        await s.disconnect()
    }
}

actor Cursor {
    var value = 0
    func set(_ v: Int) { value = v }
}

actor EventLog {
    var events: [SubscriptionEvent] = []
    func append(_ e: SubscriptionEvent) { events.append(e) }
    func count(where p: (SubscriptionEvent) -> Bool) -> Int { events.filter(p).count }
}

actor CallCounter {
    var count = 0
    func next() -> Int { count += 1; return count }
}
