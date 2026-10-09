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

    @Test func unaryRequestSucceedsAndFails() async throws {
        let (c, socket) = await makeConnection()
        async let first = c.request("server.getConfig")
        #expect(await eventually { socket.sent.count == 1 })
        #expect(socket.sent[0] == .request(RPCRequest(id: .string("1"), tag: "server.getConfig", payload: .object([:]))))
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
        #expect(socket.sent[1] == .ack(.string("1")))

        // A consumer already waiting gets the value and acks at once.
        let copy = it
        let third = Task { var waiting = copy; return try await waiting.next() }
        await settle()
        socket.deliver(.chunk(requestId: .string("1"), values: [.number(3)]))
        #expect(try await third.value == .number(3))
        #expect(await eventually { socket.sent.count == 3 })
        #expect(socket.sent[2] == .ack(.string("1")))

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
}
