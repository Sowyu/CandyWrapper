import Foundation
import Testing
@testable import T3Client
@testable import T3Transport
import T3Protocol

/// The connection fixes from docs/research/connection-vs-t3-desktop-4928.md.
struct ConnectionRecoveryTests {
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        func bump() { lock.withLock { value += 1 } }
    }

    /// The first loss of a live session retries in 125 to 250 ms, not on the 1 to 2 s rung (supervisor.ts:1286-1298).
    @Test func firstLossOfALiveSessionRetriesAlmostAtOnce() async {
        let h = Harness([.succeed, .fail(ConnectionFailure.transient("refused")), .succeed])
        let s = ConnectionSupervisor(dependencies: h.dependencies)
        await s.connect()
        #expect(await eventually { await s.state.phase == .connected })
        h.lastSocket?.close()
        // random is 0.5: 250 * (0.5 + 0.25). A server still restarting refuses that try; the next waits on the first
        // rung, 1-2 s, since the quick retry doesn't climb the ladder.
        #expect(await eventually { h.recordedSleeps.count == 2 })
        #expect(h.recordedSleeps == [.milliseconds(188), .milliseconds(1_500)])
        #expect(await eventually { await s.state.generation == 2 })
        await s.disconnect()
    }

    /// The host answers a fresh request while the socket stays silent: on loopback the socket is replaced within
    /// about a second, not at the 3 s probe deadline, and the pooled HTTP connections are reset before the
    /// reconnect (supervisor.ts:745-790).
    @Test func aSilentSocketIsReplacedOnceTheHostAnswers() async {
        let h = Harness([.succeed, .succeed])
        let lost = Counter()
        var deps = h.dependencies
        deps.checkHost = { true }
        deps.answersQuickly = true
        deps.transportLost = { lost.bump() }
        let s = ConnectionSupervisor(dependencies: deps)
        await s.connect()
        #expect(await eventually { await s.state.phase == .connected })
        let first = h.lastSocket!
        let started = ContinuousClock.now
        await s.networkPathChanged()
        #expect(await eventually(seconds: 5) { first.isClosed })
        #expect(ContinuousClock.now - started < .milliseconds(2_000))
        #expect(await eventually { await s.state.generation == 2 })
        #expect(h.recordedSleeps == [.zero])
        #expect(lost.count == 1)
        await s.disconnect()
    }

    /// A frame during the check shows the socket works, so the host answering doesn't replace it.
    @Test func aFrameDuringTheCheckKeepsTheSocket() async {
        let h = Harness([.succeed])
        var deps = h.dependencies
        let socketBox = Box<FakeSocket>()
        deps.checkHost = {
            // The socket delivers something while the host check runs.
            socketBox.value?.deliver(.pong)
            return true
        }
        deps.answersQuickly = false
        let s = ConnectionSupervisor(dependencies: deps)
        await s.connect()
        #expect(await eventually { await s.state.phase == .connected })
        let socket = h.lastSocket!
        socketBox.value = socket
        await s.networkPathChanged()
        // Past the 2.5 s remote wait, then answer the probe itself.
        try? await Task.sleep(for: .milliseconds(3_000))
        #expect(!socket.isClosed)
        let probe = socket.sent.compactMap { m -> RPCRequestID? in if case .request(let r) = m, r.tag == "server.probe" { r.id } else { nil } }.first
        if let probe { socket.deliver(.exit(requestId: probe, exit: .success(.object([:])))) }
        await settle()
        #expect(!socket.isClosed)
        #expect(await s.state.generation == 1)
        await s.disconnect()
    }

    /// A busy host may miss one foreground probe; only the follow-up's miss fails (#24309, supervisor.ts:819-822).
    @Test func aForegroundProbeAsksAgainAfterOneMiss() async {
        let socket = FakeSocket()
        let connection = RPCConnection(socket: socket, livenessInterval: .seconds(60))
        await connection.start()
        let answer = Task {
            // Answer only the second probe.
            while true {
                let probes = socket.sent.compactMap { m -> RPCRequestID? in if case .request(let r) = m, r.tag == "server.probe" { r.id } else { nil } }
                if probes.count >= 2 { socket.deliver(.exit(requestId: probes[1], exit: .success(.object([:])))); return }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        let alive = await ConnectionSupervisor.runProbe(connection, timeout: .milliseconds(200), toleratesMiss: true,
                                                        checkHost: nil, replaceAtOnce: false)
        #expect(alive)
        answer.cancel()
        let missed = await ConnectionSupervisor.runProbe(connection, timeout: .milliseconds(100), toleratesMiss: false,
                                                         checkHost: nil, replaceAtOnce: false)
        #expect(!missed)
        await connection.close()
    }

    /// Frames that start with U+001E are parts of one message (socketFrameParts.ts:56-81). Each part counts as
    /// traffic, so the liveness watchdog sees a big frame arriving.
    @Test func framePartsJoinIntoOneMessage() async throws {
        let socket = FakeSocket()
        let connection = RPCConnection(socket: socket)
        await connection.start()
        let call = Task { try await connection.request("server.getConfig") }
        #expect(await eventually { !socket.sent.isEmpty })
        guard case .request(let request) = socket.sent.first else { Issue.record("no request"); return }
        let whole = try RPCFrame.encode(.exit(requestId: request.id, exit: .success(.object(["big": .string(String(repeating: "x", count: 200))]))))
        let cut = whole.count / 3
        socket.deliverRaw(Data([0x1E]) + whole.prefix(cut))
        socket.deliverRaw(Data([0x1E]) + whole.dropFirst(cut).prefix(cut))
        socket.deliverRaw(whole.dropFirst(2 * cut))
        let value = try await call.value
        #expect(value["big"]?.stringValue?.count == 200)
        #expect(await connection.inboundFrames == 3)
        await connection.close()
    }

    /// A message the host never answers fails with T3's text and interrupts the request (#35076).
    @Test func anUnansweredMessageFailsAfterItsTimeout() async {
        let h = Harness([.succeed])
        let s = ConnectionSupervisor(dependencies: h.dependencies)
        await s.connect()
        #expect(await eventually { await s.state.phase == .connected })
        do {
            _ = try await s.dispatchMessage(.object(["type": .string("message.dispatch")]), hostLabel: "Studio", timeout: .milliseconds(100))
            Issue.record("no timeout")
        } catch let error as RPCClientError {
            #expect(error.typedError?.message == "Studio did not confirm the message within 0 seconds.")
        } catch {
            Issue.record("\(error)")
        }
        #expect(await eventually { h.lastSocket!.sent.contains { if case .interrupt = $0 { true } else { false } } })
        #expect(await s.state.phase == .connected)
        await s.disconnect()
    }

    @Test func socketURLsAskForFrameParts() {
        let http = EnvironmentHTTP(baseURL: URL(string: "http://127.0.0.1:47391")!)
        let url = http.webSocketURL(ticket: "t", identity: ClientIdentity(appVersion: "1"))
        #expect(url.query?.hasSuffix("orchestrationProtocol=2&frameParts=1&clientCapabilities=httpUsageLimitSources") == true)
    }

    @Test func routeKindsMatchT3() {
        for host in ["http://127.0.0.1:3773", "http://localhost:1", "http://192.168.1.4", "http://10.0.0.2", "http://172.20.1.1", "http://mini.local"] {
            #expect(ConnectionSupervisor.RouteKind.answersQuickly(URL(string: host)!), "\(host)")
        }
        for host in ["https://prod-abc.tunnel.example", "http://100.64.1.2", "http://172.32.0.1", "http://8.8.8.8"] {
            #expect(!ConnectionSupervisor.RouteKind.answersQuickly(URL(string: host)!), "\(host)")
        }
    }
}

final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?
    var value: T? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

extension T3ConnectAuthorizerTests {
    /// A live relay socket renews its token in the session's last minute, so a 4928 server moves the socket to the
    /// new session instead of closing it at the hour (#27998, driver.ts:250-266, service.ts:784-812).
    @Test func aLiveSocketRenewsItsTokenBeforeExpiry() async throws {
        serveHappyPath()
        let authorizer = try makeAuthorizer()
        let token = try await authorizer.token(environmentId: "env-1")
        let socket = FakeSocket()
        let connection = RPCConnection(socket: socket)
        await connection.start()
        let sleeps = Box<[TimeInterval]>()
        sleeps.value = []
        authorizer.keepSessionAlive(connection, environmentId: "env-1", expiresAt: token.expiresAt) { [clock] seconds in
            sleeps.value = (sleeps.value ?? []) + [seconds]
            // Park after the renewal so the test can look.
            if (sleeps.value ?? []).count > 1 { try await Task.sleep(for: .seconds(3600)) }
            clock.advance(seconds)
        }
        #expect(await eventually { http.requests.filter { $0.url?.path == "/oauth/token" }.count == 2 })
        #expect(sleeps.value?.first == 3540)
        // The next renewal waits for the new token's last minute.
        #expect(await eventually { (sleeps.value ?? []).count == 2 })
        #expect(sleeps.value?.last == 3540)
        await connection.close()
    }
}
