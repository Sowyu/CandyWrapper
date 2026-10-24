import Foundation
import Testing
@testable import T3Client
@testable import T3Transport
import T3Protocol

struct RPCConnectionTests {
    func makeConnection() async -> (RPCConnection, FakeSocket) {
        let socket = FakeSocket()
        let connection = RPCConnection(socket: socket)
        await connection.start()
        return (connection, socket)
    }

    @Test func futureRecordedPushesAndUnknownRPCFailuresKeepTheConnection() async throws {
        let (connection, socket) = await makeConnection()
        defer { socket.close() }
        let stream = await connection.stream("orchestration.subscribeThread")
        async let config = connection.request("server.getConfig")
        #expect(await eventually { socket.sent.count == 2 })
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appending(path: "fixtures/transcripts/21-future-server.jsonl"), encoding: .utf8)
        var count = 0
        for line in text.split(separator: "\n") {
            let record = try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
            guard record["dir"]?.stringValue == "recv", let body = record["body"] else { continue }
            for message in try RPCFrame.decodeServer(JSONEncoder().encode(body)) {
                switch message {
                case .chunk(let id, let values) where id == .string("4"):
                    count += values.count
                    socket.deliver(.chunk(requestId: .string("1"), values: values))
                case .exit(let id, let result) where id == .string("1"):
                    socket.deliver(.exit(requestId: .string("2"), exit: result))
                case .unknown: socket.deliver(message)
                default: break
                }
            }
        }
        var iterator = stream.makeAsyncIterator()
        var snapshotSeen = false
        for _ in 0..<count {
            let value = try #require(try await iterator.next())
            let item = try value.decode(as: ThreadStreamItem.self)
            if case .snapshot = item { snapshotSeen = true }
        }
        #expect(snapshotSeen)
        #expect(try await config["providers"]?.arrayValue?.first?["driver"]?.stringValue == "futureProvider")
        async let unknown = connection.request("server.futureMethod")
        #expect(await eventually { socket.sent.contains { if case .request(let r) = $0 { return r.tag == "server.futureMethod" }; return false } })
        socket.deliver(.exit(requestId: .string("3"), exit: .failure([.fail(RPCTypedError(tag: "FutureMethodUnavailable", fields: ["message": .string("Unavailable")]))])))
        do { _ = try await unknown; Issue.record("Expected an RPC error") }
        catch let error as RPCClientError { #expect(error.typedError?.tag == "FutureMethodUnavailable") }
        #expect(!(await connection.isClosed))
        async let next = connection.request("server.getConfig")
        #expect(await eventually { socket.sent.contains { if case .request(let r) = $0 { return r.id == .string("4") }; return false } })
        socket.deliver(.exit(requestId: .string("4"), exit: .success(.string("still connected"))))
        #expect(try await next == .string("still connected"))
        await connection.close()
    }

    @Test func unaryRequestSucceedsAndFails() async throws {
        let (c, socket) = await makeConnection()
        async let first = c.request("server.getConfig")
        #expect(await eventually { socket.sent.count == 1 })
        #expect(socket.sent.first == .request(RPCRequest(id: .string("1"), tag: "server.getConfig", payload: .object([:]))))
        socket.deliver(.exit(requestId: .string("1"), exit: .success(.object(["ok": .bool(true)]))))
        #expect(try await first == .object(["ok": .bool(true)]))

        async let second = c.request("orchestration.dispatchCommand")
        #expect(await eventually { socket.sent.count == 2 })
        let fail = RPCTypedError(tag: "OrchestrationV2DispatchCommandError", fields: ["message": .string("nope")])
        socket.deliver(.exit(requestId: .string("2"), exit: .failure([.fail(fail)])))
        do {
            _ = try await second
            Issue.record("expected failure")
        } catch let e as RPCClientError {
            #expect(e.typedError?.tag == "OrchestrationV2DispatchCommandError")
            #expect(e.description == "nope")
        }
    }

    @Test func streamAcksOnlyAfterConsumerTakesTheChunk() async throws {
        let (c, socket) = await makeConnection()
        let stream = await c.stream("orchestration.subscribeShell", payload: .object(["requestCompletionMarker": .bool(true)]))
        var it = stream.makeAsyncIterator()
        #expect(await eventually { socket.sent.count == 1 })

        socket.deliver(.chunk(requestId: .string("1"), values: [.number(1), .number(2)]))
        await settle()
        #expect(socket.sent.count == 1, "no ack before the consumer pulls")

        #expect(try await it.next() == .number(1))
        await settle()
        #expect(socket.sent.count == 1, "no ack while part of the chunk is unread")

        #expect(try await it.next() == .number(2))
        #expect(await eventually { socket.sent.count == 2 })
        #expect(socket.sent.dropFirst().first == .ack(.string("1")))

        // A consumer already waiting gets the value and acks at once.
        let copy = it
        let third = Task { var waiting = copy; return try await waiting.next() }
        await settle()
        socket.deliver(.chunk(requestId: .string("1"), values: [.number(3)]))
        #expect(try await third.value == .number(3))
        #expect(await eventually { socket.sent.count == 3 })
        #expect(socket.sent.dropFirst(2).first == .ack(.string("1")))

        socket.deliver(.exit(requestId: .string("1"), exit: .success(.null)))
        #expect(try await it.next() == nil)
    }

    @Test func streamAcksEachBufferedChunk() async throws {
        let (c, socket) = await makeConnection()
        let stream = await c.stream("terminal.attach")
        var it = stream.makeAsyncIterator()
        #expect(await eventually { socket.sent.count == 1 })

        // Two chunks wait in the buffer. T3's terminal window frees one chunk per Ack.
        socket.deliver(.chunk(requestId: .string("1"), values: [.number(1)]))
        socket.deliver(.chunk(requestId: .string("1"), values: [.number(2), .number(3)]))
        await settle()
        #expect(socket.sent.count == 1)

        #expect(try await it.next() == .number(1))
        #expect(await eventually { socket.sent.count == 2 })
        #expect(try await it.next() == .number(2))
        await settle()
        #expect(socket.sent.count == 2, "no ack while part of the second chunk is unread")
        #expect(try await it.next() == .number(3))
        #expect(await eventually { socket.sent.count == 3 })
        #expect(Array(socket.sent.dropFirst()) == [.ack(.string("1")), .ack(.string("1"))])
    }

    @Test func cancellingTheConsumerSendsInterrupt() async throws {
        let (c, socket) = await makeConnection()
        let stream = await c.stream("orchestration.subscribeShell")
        let consumer = Task { () -> Int in
            var n = 0
            for try await _ in stream { n += 1 }
            return n
        }
        socket.deliver(.chunk(requestId: .string("1"), values: [.string("snapshot")]))
        #expect(await eventually { socket.sent.contains(.ack(.string("1"))) })
        consumer.cancel()
        #expect(await eventually { socket.sent.last == .interrupt(.string("1")) })
        #expect(try await consumer.value == 1)
    }

    @Test func droppingTheStreamSendsInterrupt() async throws {
        let (c, socket) = await makeConnection()
        do {
            _ = await c.stream("orchestration.subscribeThread")
        }
        #expect(await eventually { socket.sent.last == .interrupt(.string("1")) })
    }

    @Test func cancellingAUnaryCallSendsInterrupt() async throws {
        let (c, socket) = await makeConnection()
        let call = Task { try await c.request("server.getSettings") }
        #expect(await eventually { socket.sent.count == 1 })
        call.cancel()
        #expect(await eventually { socket.sent.last == .interrupt(.string("1")) })
        await #expect(throws: CancellationError.self) { try await call.value }
    }

    @Test func socketCloseFailsEverythingPending() async throws {
        let (c, socket) = await makeConnection()
        let call = Task { try await c.request("server.getConfig") }
        let stream = await c.stream("orchestration.subscribeShell")
        let consumer = Task { for try await _ in stream {} }
        #expect(await eventually { socket.sent.count == 2 })
        socket.close()
        for result in [await call.result.map { _ in () }, await consumer.result] {
            guard case .failure(let e as RPCClientError) = result, e.isTransport else {
                Issue.record("expected transport error, got \(result)")
                continue
            }
        }
        #expect(await c.isClosed)
        // Calls after the close fail at once.
        await #expect(throws: RPCClientError.self) { try await c.request("server.probe") }
    }

    @Test func pingWaitsForPong() async throws {
        let (c, socket) = await makeConnection()
        let ping = Task { try await c.ping(timeout: .seconds(2)) }
        #expect(await eventually { socket.sent.last == .ping })
        socket.deliver(.pong)
        try await ping.value
        await #expect(throws: RPCTransportError.pingTimedOut) { try await c.ping(timeout: .milliseconds(30)) }
    }

    // MARK: Frames the connection can't use

    @Test func anUndecodableFrameClosesTheConnectionAndFailsPendingCalls() async throws {
        let (c, socket) = await makeConnection()
        let call = Task { try await c.request("server.getConfig") }
        #expect(await eventually { socket.sent.count == 1 })
        socket.deliverRaw(Data("not json {".utf8))
        guard case .failure(let e as RPCClientError) = await call.result, e.isTransport else {
            Issue.record("expected the call to fail with a transport error"); return
        }
        #expect(await c.waitUntilClosed() == .transport(.invalidFrame("undecodable frame")))
        #expect(await c.isClosed)
        #expect(socket.isClosed)
    }

    @Test func aFailedSendClosesTheConnectionAndFailsPendingCalls() async throws {
        let (c, socket) = await makeConnection()
        let stream = await c.stream("orchestration.subscribeShell")
        let consumer = Task { for try await _ in stream {} }
        #expect(await eventually { socket.sent.count == 1 })
        socket.failNextSend()
        let call = Task { try await c.request("server.getConfig") }
        for result in [await call.result.map { _ in () }, await consumer.result] {
            guard case .failure(let e as RPCClientError) = result, e.isTransport else {
                Issue.record("expected a transport error, got \(result)"); continue
            }
        }
        guard case .transport(.closed(let reason)) = await c.waitUntilClosed() else {
            Issue.record("expected a closed transport error"); return
        }
        #expect(reason.hasPrefix("send failed"))
        #expect(socket.isClosed)
    }

    // MARK: Liveness while a reply is owed (the abuse test's half-closed socket, 2026-10-12)

    static let interval = Duration.seconds(5)

    func makeWatchedConnection() async -> (RPCConnection, FakeSocket, ManualClock) {
        let socket = FakeSocket()
        let clock = ManualClock()
        let connection = RPCConnection(socket: socket, livenessInterval: Self.interval, clock: clock.clock)
        await connection.start()
        return (connection, socket, clock)
    }

    func pings(_ socket: FakeSocket) -> Int { socket.sent.filter { $0 == .ping }.count }

    /// Moves the clock one liveness interval and waits until the watchdog has run its tick: it either
    /// sleeps again or has stopped.
    func tick(_ c: RPCConnection, _ clock: ManualClock) async {
        #expect(await eventually { clock.waiting == 1 }, "the watchdog sleeps")
        let before = clock.sleepCount
        clock.advance(by: Self.interval)
        #expect(await eventually {
            if clock.sleepCount > before { return true }
            return await !c.watchdogRunning
        })
    }

    /// Delivers a Pong and waits until the connection has taken it.
    func pong(_ c: RPCConnection, _ socket: FakeSocket) async {
        socket.deliver(.pong)
        #expect(await eventually { !(await c.pingOutstanding) })
    }

    @Test func aSilentSocketWithACallOwedIsClosed() async throws {
        let (c, socket, clock) = await makeWatchedConnection()
        let call = Task { try await c.request("server.getConfig") }
        #expect(await eventually { socket.sent.count == 1 })
        // Nothing comes back: one quiet interval sends a Ping, three without any frame close.
        await tick(c, clock)
        #expect(await eventually { pings(socket) == 1 })
        await tick(c, clock)
        #expect(await !c.isClosed)
        await tick(c, clock)
        #expect(await c.isClosed)
        #expect(pings(socket) == 1)
        guard case .failure(let e as RPCClientError) = await call.result, e == .transport(.pingTimedOut) else {
            Issue.record("expected the call to fail with pingTimedOut"); return
        }
    }

    @Test func aSlowCallOnALiveSocketKeepsItOpenAndTheWatchdogEnds() async throws {
        let (c, socket, clock) = await makeWatchedConnection()
        let call = Task { try await c.request("git.slowThing") }
        #expect(await eventually { socket.sent.count == 1 })
        // Answer two pings, then the call.
        for n in 1...2 {
            await tick(c, clock)
            #expect(await eventually { pings(socket) == n })
            await pong(c, socket)
        }
        #expect(await !c.isClosed)
        socket.deliver(.exit(requestId: .string("1"), exit: .success(.null)))
        _ = try await call.value
        // Nothing is owed any more: the watchdog is gone, so time passing sends nothing.
        #expect(await !c.watchdogRunning)
        clock.advance(by: Self.interval * 10)
        #expect(clock.waiting == 0)
        #expect(pings(socket) == 2)
        #expect(await !c.isClosed)
    }

    @Test func aQuietSubscriptionNeedsOnePongThenNothing() async throws {
        let (c, socket, clock) = await makeWatchedConnection()
        let stream = await c.stream("terminal.subscribe")
        let consumer = Task { for try await _ in stream {} }
        #expect(await eventually { socket.sent.count == 1 })
        await tick(c, clock)
        #expect(await eventually { pings(socket) == 1 })
        // The Pong answers the subscription, so the watchdog stops with it.
        await pong(c, socket)
        #expect(await !c.watchdogRunning)
        #expect(await !c.isClosed)
        consumer.cancel()
        #expect(await eventually { socket.sent.last == .interrupt(.string("1")) })
        #expect(pings(socket) == 1)
    }

    @Test func aStreamThatAnswersAtOnceNeverPings() async throws {
        let (c, socket, clock) = await makeWatchedConnection()
        let shell = await c.stream("orchestration.subscribeShell")
        let consumer = Task { for try await _ in shell {} }
        #expect(await eventually { socket.sent.count == 1 })
        socket.deliver(.chunk(requestId: .string("1"), values: [.object([:])]))
        #expect(await eventually { socket.sent.contains(.ack(.string("1"))) })
        #expect(await !c.watchdogRunning)
        clock.advance(by: Self.interval * 10)
        #expect(pings(socket) == 0)
        consumer.cancel()
    }

    /// T3 allows 15 s, three of its 5 s ping intervals, without any frame (rpc/protocol.ts:10-12).
    @Test func aServerBusyForTwoIntervalsIsNotDropped() async throws {
        let (c, socket, clock) = await makeWatchedConnection()
        let call = Task { try await c.request("server.getConfig") }
        #expect(await eventually { socket.sent.count == 1 })
        // Silent for two intervals: the old watchdog closed here.
        await tick(c, clock)
        await tick(c, clock)
        #expect(await !c.isClosed)
        socket.deliver(.exit(requestId: .string("1"), exit: .success(.null)))
        _ = try await call.value
        #expect(await !c.isClosed)
    }

    @Test func anUnwatchedIdleSocketSendsNothing() async throws {
        let (c, socket, clock) = await makeWatchedConnection()
        clock.advance(by: Self.interval * 10)
        #expect(clock.sleepCount == 0, "nothing owed, nothing watched: no watchdog")
        #expect(await !c.watchdogRunning)
        #expect(socket.sent.isEmpty)
        #expect(await !c.isClosed)
    }

    @Test func aWatchedSocketPingsWhileQuietAndStopsWhenUnwatched() async throws {
        let (c, socket, clock) = await makeWatchedConnection()
        await c.setWatched(true)
        for n in 1...2 {
            await tick(c, clock)
            #expect(await eventually { pings(socket) == n })
            await pong(c, socket)
        }
        #expect(await !c.isClosed)
        await c.setWatched(false)
        // The next tick sees nothing watched or owed and ends the watchdog without a Ping.
        await tick(c, clock)
        #expect(await !c.watchdogRunning)
        #expect(pings(socket) == 2)
    }

    @Test func aStaleWatchToggleChangesNothing() async throws {
        let (c, _, clock) = await makeWatchedConnection()
        await c.setWatched(false, generation: 2)
        await c.setWatched(true, generation: 1)
        #expect(await !c.watchdogRunning)
        #expect(clock.sleepCount == 0)
    }

    @Test func aWatchedSilentSocketIsClosed() async throws {
        let (c, socket, clock) = await makeWatchedConnection()
        await c.setWatched(true)
        await tick(c, clock)
        #expect(await eventually { pings(socket) == 1 })
        await tick(c, clock)
        await tick(c, clock)
        #expect(await c.isClosed)
        #expect(await c.waitUntilClosed() == .transport(.pingTimedOut))
    }
}
