import Foundation
import Network
import Testing
@testable import T3Client
@testable import T3Transport
import T3Protocol

/// The offline and syncing fixes and the timer-free liveness checks from connection-2
/// (docs/research/connection-vs-t3-desktop-4928.md).
struct ConnectionSignalTests {
    private func requests(_ socket: FakeSocket, _ tag: String) -> [RPCRequestID] {
        socket.sent.compactMap { m -> RPCRequestID? in if case .request(let r) = m, r.tag == tag { r.id } else { nil } }
    }

    /// Reconnect tries even while the device reports offline, since that report can stay wrong after the network is
    /// back (supervisor.ts:1213-1221). Before, the press did nothing and the banner kept saying offline.
    @Test func reconnectTriesWhileThePlatformSaysOffline() async {
        let h = Harness([.succeed])
        let s = ConnectionSupervisor(dependencies: h.dependencies)
        await s.networkChanged(online: false)
        await s.connect()
        #expect(await s.state.phase == .offline)
        #expect(h.attemptCount == 0)
        await s.retryNow()
        #expect(await eventually { await s.state.phase == .connected })
        await s.disconnect()
    }

    /// A socket that a probe found dead is replaced even while the device reports offline (`replacing`, supervisor.ts:1220).
    @Test func aFailedProbeReplacesTheSocketWhileThePlatformSaysOffline() async {
        let h = Harness([.succeed, .succeed])
        var deps = h.dependencies
        deps.checkHost = { true }
        deps.answersQuickly = true
        let s = ConnectionSupervisor(dependencies: deps)
        await s.connect()
        #expect(await eventually { await s.state.phase == .connected })
        // Going offline probes the live socket; the fake never answers and the host does, so it is replaced.
        await s.networkChanged(online: false)
        #expect(await eventually(seconds: 5) { await s.state.generation == 2 })
        await s.disconnect()
    }

    /// A host on this device never parks on the device's offline report (supervisor.ts:323-327).
    @Test func aLoopbackHostIgnoresTheOfflineReport() async {
        let h = Harness([.succeed])
        var deps = h.dependencies
        deps.ignoresOffline = true
        let s = ConnectionSupervisor(dependencies: deps)
        await s.networkChanged(online: false)
        await s.connect()
        #expect(await eventually { await s.state.phase == .connected })
        await s.disconnect()
        #expect(ConnectionSupervisor.RouteKind.isLoopback(URL(string: "http://127.0.0.1:3773")!))
        #expect(ConnectionSupervisor.RouteKind.isLoopback(URL(string: "http://localhost:3773")!))
        #expect(!ConnectionSupervisor.RouteKind.isLoopback(URL(string: "http://192.168.1.4:3773")!))
    }

    /// NWPathMonitor updates hop to the actor in separate tasks. An "offline" that lands after the "online" it preceded
    /// used to park the environment offline until the next path update.
    @Test func aLateOfflineUpdateDoesNotUndoTheOnlineOneAfterIt() async {
        let h = Harness([.succeed])
        let s = ConnectionSupervisor(dependencies: h.dependencies)
        await s.pathUpdated(online: false, moved: false, sequence: 1)
        await s.pathUpdated(online: true, moved: false, sequence: 3)
        await s.pathUpdated(online: false, moved: false, sequence: 2)
        await s.connect()
        #expect(await eventually { await s.state.phase == .connected })
        await s.disconnect()
    }

    @Test func onlyAnUnsatisfiedPathIsOffline() {
        #expect(PlatformSignals.isOnline(.satisfied))
        #expect(PlatformSignals.isOnline(.requiresConnection))
        #expect(!PlatformSignals.isOnline(.unsatisfied))
    }

    /// Input after the socket was silent past the threshold probes it; input on a socket that just spoke doesn't.
    @Test func inputAfterAQuietStretchProbesTheSocket() async throws {
        let h = Harness([.succeed])
        let s = ConnectionSupervisor(dependencies: h.dependencies)
        await s.connect()
        #expect(await eventually { await s.state.phase == .connected })
        let socket = h.lastSocket!
        let fresh = await s.inputAfterQuiet(threshold: .seconds(15))
        #expect(fresh?.probed == false)
        #expect((fresh?.recheckIn ?? .zero) > .seconds(14))
        #expect(requests(socket, "server.probe").isEmpty)
        try await Task.sleep(for: .milliseconds(120))
        let quiet = await s.inputAfterQuiet(threshold: .milliseconds(100))
        #expect(quiet?.probed == true)
        #expect(await eventually { requests(socket, "server.probe").count == 1 })
        await s.disconnect()
    }

    /// The gate does one comparison per input until the soonest socket could be quiet, then asks every supervisor.
    @MainActor @Test func theGateChecksOnlyOncePerQuietStretch() async throws {
        let h = Harness([.succeed])
        let s = ConnectionSupervisor(dependencies: h.dependencies)
        await s.connect()
        #expect(await eventually { await s.state.phase == .connected })
        let gate = InputQuietGate(threshold: .milliseconds(100))
        gate.register(s)
        var quietInputs = 0
        gate.observeQuietInput { quietInputs += 1 }
        await gate.check(at: 1_000)
        // The socket just opened: nothing to ask yet, and the next check waits for the rest of the threshold.
        #expect(quietInputs == 0)
        #expect(gate.nextCheck > 1_000 && gate.nextCheck <= 1_000.1)
        try await Task.sleep(for: .milliseconds(150))
        await gate.check(at: 1_000.2)
        #expect(quietInputs == 1)
        #expect(abs(gate.nextCheck - 1_000.3) < 0.001)
        #expect(await eventually { requests(h.lastSocket!, "server.probe").count == 1 })
        await s.disconnect()
    }

    /// App activation subscribes again on the same session (wakeups.ts:25-27, rpc/client.ts:284-330), only for the
    /// subscriptions that ask for it. Before, a stream that died without an error stayed dead.
    @Test func activationResubscribesOnTheSameSession() async {
        let h = Harness([.succeed])
        let s = ConnectionSupervisor(dependencies: h.dependencies)
        await s.connect()
        #expect(await eventually { await s.state.phase == .connected })
        let socket = h.lastSocket!
        let resubscribing = s.subscribe("orchestration.subscribeShell", resubscribesOnActivation: true, payload: { .object([:]) }, handler: { _ in })
        let plain = s.subscribe("orchestration.subscribeServerConfig", payload: { .object([:]) }, handler: { _ in })
        #expect(await eventually { requests(socket, "orchestration.subscribeShell").count == 1
            && requests(socket, "orchestration.subscribeServerConfig").count == 1 })
        let first = requests(socket, "orchestration.subscribeShell")[0]
        await s.wakeup(.applicationActive)
        #expect(await eventually { requests(socket, "orchestration.subscribeShell").count == 2 })
        #expect(await eventually { socket.sent.contains { if case .interrupt(first) = $0 { true } else { false } } })
        await settle()
        #expect(requests(socket, "orchestration.subscribeServerConfig").count == 1)
        #expect(await s.state.generation == 1)
        resubscribing.cancel(); plain.cancel()
        await s.disconnect()
    }

    /// All routes are checked at once and the first in preference order that answers wins (driver.ts:83-130).
    @Test func theFirstAnsweringRouteWinsWithoutWaitingInTurn() async {
        let lan = URL(string: "http://192.168.1.4:3773")!, tailnet = URL(string: "http://100.64.0.2:3773")!
        let relay = URL(string: "https://tunnel.example.com")!
        let started = ContinuousClock.now
        let picked = await RouteCheck.check([lan, tailnet, relay]) { route in
            if route == lan { try? await Task.sleep(for: .milliseconds(300)); return false }
            if route == tailnet { try? await Task.sleep(for: .milliseconds(300)); return false }
            return true
        }
        #expect(picked == RouteCheck.Outcome(first: relay, silent: [lan, tailnet]))
        // Both dead routes ran side by side: one timeout, not two.
        #expect(ContinuousClock.now - started < .milliseconds(550))
        let preferred = await RouteCheck.check([lan, relay]) { route in
            if route == lan { try? await Task.sleep(for: .milliseconds(100)) }
            return true
        }
        #expect(preferred.first == lan)
        #expect(await RouteCheck.check([lan]) { _ in false } == RouteCheck.Outcome(first: nil, silent: [lan]))
    }

    /// A route that hasn't answered within T3's 500 ms head start is passed over (driver.ts:65, 95-133): a LAN address
    /// on another network never answers, and the tunnel behind it shouldn't wait out its 2.5 s check.
    @Test func aSilentRouteIsPassedOverAfterTheHeadStart() async {
        let lan = URL(string: "http://192.168.1.4:3773")!, tailnet = URL(string: "http://100.64.0.2:3773")!
        let relay = URL(string: "https://tunnel.example.com")!
        let started = ContinuousClock.now
        let picked = await RouteCheck.check([lan, relay]) { route in
            if route == lan { try? await Task.sleep(for: .milliseconds(2_500)); return false }
            return true
        }
        let waited = ContinuousClock.now - started
        #expect(picked == RouteCheck.Outcome(first: relay, silent: []))
        #expect(waited >= .milliseconds(450) && waited < .milliseconds(1_500))
        // A later route that answers after the head start still wins over a silent one ahead of it.
        let late = await RouteCheck.check([lan, tailnet, relay]) { route in
            if route == lan { try? await Task.sleep(for: .milliseconds(2_500)); return true }
            if route == tailnet { try? await Task.sleep(for: .milliseconds(700)); return true }
            return false
        }
        #expect(late.first == tailnet)
        #expect(late.silent == [relay])
        // Every route failed: no answer, without waiting for the head start.
        let quick = ContinuousClock.now
        #expect(await RouteCheck.check([lan, relay]) { _ in false } == RouteCheck.Outcome(first: nil, silent: [lan, relay]))
        #expect(ContinuousClock.now - quick < .milliseconds(400))
    }

    @Test func betterRoutesAndTheirBackoff() {
        let lan = URL(string: "http://192.168.1.4:3773")!, tailnet = URL(string: "http://100.64.0.2:3773")!
        let relay = URL(string: "https://tunnel.example.com")!
        let routes = [lan, tailnet, relay]
        #expect(RouteCheck.better(than: relay, in: routes, skipping: { _ in false }) == [lan, tailnet])
        #expect(RouteCheck.better(than: lan, in: routes, skipping: { _ in false }).isEmpty)
        var backoff = RouteBackoff()
        let now = Date()
        backoff.silent(lan, now: now)
        #expect(backoff.skips(lan, now: now + 119))
        #expect(!backoff.skips(lan, now: now + 121))
        backoff.silent(lan, now: now)
        #expect(backoff.skips(lan, now: now + 239))
        #expect(RouteCheck.better(than: relay, in: routes, skipping: { backoff.skips($0, now: now) }) == [tailnet])
        backoff.networkChanged()
        #expect(!backoff.skips(lan, now: now))
        backoff.switchFailed(tailnet, now: now)
        #expect(backoff.skips(tailnet, now: now + 299))
        backoff.networkChanged()
        #expect(backoff.skips(tailnet, now: now + 299))
    }
}
