import Foundation
import Testing
@testable import T3Client
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

    // MARK: Liveness while a reply is owed (the abuse test's half-closed socket, 2026-10-12)

    func makeWatchedConnection() async -> (RPCConnection, FakeSocket) {
        let socket = FakeSocket()
        let connection = RPCConnection(socket: socket, livenessInterval: .milliseconds(60))
        await connection.start()
        return (connection, socket)
    }

    func pings(_ socket: FakeSocket) -> Int { socket.sent.filter { $0 == .ping }.count }

    @Test func aSilentSocketWithACallOwedIsClosed() async throws {
        let (c, socket) = await makeWatchedConnection()
        let call = Task { try await c.request("server.getConfig") }
        // Nothing comes back: one quiet interval sends a Ping, a second one without a Pong closes.
        #expect(await eventually { pings(socket) == 1 })
        #expect(await eventually { await c.isClosed })
        guard case .failure(let e as RPCClientError) = await call.result, e == .transport(.pingTimedOut) else {
            Issue.record("expected the call to fail with pingTimedOut"); return
        }
    }

    @Test func aSlowCallOnALiveSocketKeepsItOpenAndTheWatchdogEnds() async throws {
        let (c, socket) = await makeWatchedConnection()
        let call = Task { try await c.request("git.slowThing") }
        // Answer two pings, then the call.
        for n in 1...2 {
            #expect(await eventually { pings(socket) == n })
            socket.deliver(.pong)
        }
        #expect(await !c.isClosed)
        socket.deliver(.exit(requestId: .string("1"), exit: .success(.null)))
        _ = try await call.value
        // Nothing is owed any more: no further pings.
        let after = pings(socket)
        try await Task.sleep(for: .milliseconds(250))
        #expect(pings(socket) == after)
        #expect(await !c.isClosed)
    }

    @Test func aQuietSubscriptionNeedsOnePongThenNothing() async throws {
        let (c, socket) = await makeWatchedConnection()
        let stream = await c.stream("terminal.subscribe")
        let consumer = Task { for try await _ in stream {} }
        #expect(await eventually { pings(socket) == 1 })
        socket.deliver(.pong)
        try await Task.sleep(for: .milliseconds(250))
        #expect(pings(socket) == 1)
        #expect(await !c.isClosed)
        // A stream that answers at once never pings at all.
        let (c2, socket2) = await makeWatchedConnection()
        let shell = await c2.stream("orchestration.subscribeShell")
        let consumer2 = Task { for try await _ in shell {} }
        #expect(await eventually { socket2.sent.count == 1 })
        socket2.deliver(.chunk(requestId: .string("1"), values: [.object([:])]))
        try await Task.sleep(for: .milliseconds(250))
        #expect(pings(socket2) == 0)
        consumer.cancel(); consumer2.cancel()
    }

    /// T3 allows 15 s, three of its 5 s ping intervals, without any frame (rpc/protocol.ts:10-12).
    @Test func aServerBusyForTwoIntervalsIsNotDropped() async throws {
        let (c, socket) = await makeWatchedConnection()
        let call = Task { try await c.request("server.getConfig") }
        // Silent for two and a half intervals: the old watchdog closed after two.
        try await Task.sleep(for: .milliseconds(150))
        #expect(await !c.isClosed)
        socket.deliver(.exit(requestId: .string("1"), exit: .success(.null)))
        _ = try await call.value
        #expect(await !c.isClosed)
    }

    @Test func aWatchedIdleSocketIsCheckedAndAnUnwatchedOneIsNot() async throws {
        let (idle, idleSocket) = await makeWatchedConnection()
        try await Task.sleep(for: .milliseconds(250))
        #expect(idleSocket.sent.isEmpty, "nothing owed, nothing watched: no traffic")
        #expect(await !idle.isClosed)

        // Watched and answering: open, with pings only while quiet.
        await idle.setWatched(true)
        for n in 1...2 {
            #expect(await eventually { pings(idleSocket) == n })
            idleSocket.deliver(.pong)
        }
        #expect(await !idle.isClosed)
        await idle.setWatched(false)
        try await Task.sleep(for: .milliseconds(150))
        let after = pings(idleSocket)
        try await Task.sleep(for: .milliseconds(250))
        #expect(pings(idleSocket) == after, "unwatched again: the watchdog stopped")

        // An older toggle that lands late changes nothing.
        await idle.setWatched(false, generation: 2)
        await idle.setWatched(true, generation: 1)
        try await Task.sleep(for: .milliseconds(250))
        #expect(pings(idleSocket) == after, "a stale watch didn't restart the watchdog")

        // Watched and silent: closed.
        let (dead, deadSocket) = await makeWatchedConnection()
        await dead.setWatched(true)
        #expect(await eventually { pings(deadSocket) == 1 })
        #expect(await eventually { await dead.isClosed })
        #expect(await dead.waitUntilClosed() == .transport(.pingTimedOut))
    }
}
