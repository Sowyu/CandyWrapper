import Foundation
import Testing
@testable import T3Client
@testable import T3Transport
import T3Protocol

/// In-memory fault injection for the transport audit. No server or credentials.
struct TransportResponsivenessAuditTests {
    @Test(.timeLimit(.minutes(1)))
    func concurrentCancellationAndReversedRepliesKeepRequestIdentity() async throws {
        let socket = FakeSocket()
        let connection = RPCConnection(socket: socket)
        await connection.start()
        defer { socket.close() }
        let calls = (0..<64).map { index in
            Task { try await connection.request("audit.echo", payload: .number(Double(index))) }
        }
        let stream = await connection.stream("audit.stream")
        #expect(await eventually(seconds: 3) {
            socket.sent.filter { if case .request = $0 { return true }; return false }.count == 65
        })
        let requests = socket.sent.compactMap { message -> RPCRequest? in
            if case .request(let request) = message { return request }
            return nil
        }
        let streamRequest = try #require(requests.first { $0.tag == "audit.stream" })
        for index in calls.indices where index % 3 == 0 { calls[index].cancel() }
        #expect(await eventually(seconds: 3) {
            socket.sent.filter { if case .interrupt = $0 { return true }; return false }.count == 22
        })
        // Queue several chunks before the consumer pulls. Replies, including late cancelled
        // replies, arrive in reverse request order between the stream's chunks.
        for request in requests.reversed() where request.tag == "audit.echo" {
            socket.deliver(.exit(requestId: request.id, exit: .success(request.payload)))
        }
        for index in 0..<16 {
            socket.deliver(.chunk(requestId: streamRequest.id, values: [
                .number(Double(index * 2)), .number(Double(index * 2 + 1)),
            ]))
        }
        var iterator = stream.makeAsyncIterator()
        for index in 0..<32 {
            #expect(try await iterator.next() == .number(Double(index)))
        }
        #expect(await eventually(seconds: 3) {
            socket.sent.filter { $0 == .ack(streamRequest.id) }.count == 16
        })
        for (index, call) in calls.enumerated() {
            switch await call.result {
            case .success(let value):
                #expect(index % 3 != 0)
                #expect(value == .number(Double(index)))
            case .failure(let error):
                #expect(index % 3 == 0 && error is CancellationError)
            }
        }
        socket.deliver(.exit(requestId: streamRequest.id, exit: .success(.null)))
        #expect(try await iterator.next() == nil)
        await connection.close()
    }

    /// Intentionally fails on the audited source. Enable only for the centralized audit run.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CANDY_TRANSPORT_AUDIT_FAILURES"] == "1"),
          .timeLimit(.minutes(1)))
    func pongBeforeInitialConfigMustNotRemoveLoadingRecovery() async throws {
        let socket = FakeSocket()
        let clock = ManualClock()
        let connection = RPCConnection(socket: socket, livenessInterval: .seconds(5), clock: clock.clock)
        await connection.start()
        defer { socket.close() }
        let supervisor = ConnectionSupervisor(dependencies: .init(connect: { connection }))
        let feed = ServerConfigFeed(supervisor: supervisor)
        await supervisor.connect()
        await feed.start()
        #expect(await eventually(seconds: 3) {
            socket.sent.contains { if case .request(let request) = $0 { return request.tag == "subscribeServerConfig" }; return false }
        })
        let generation = await supervisor.state.generation
        let reader = Task { await feed.initialConfig(generation: generation) }
        #expect(await eventually(seconds: 3) { clock.waiting == 1 })
        clock.advance(by: .seconds(5))
        #expect(await eventually(seconds: 3) { socket.sent.contains(.ping) })
        socket.deliver(.pong)
        #expect(await eventually(seconds: 3) { await !connection.watchdogRunning })
        // The host now disappears without a TCP close. Config never sent its snapshot.
        // All virtual deadlines pass, but the connection has no watchdog left to run.
        clock.advance(by: .seconds(60))
        #expect(await connection.isClosed, "A pending initial snapshot still needs loading recovery after Pong")
        await feed.stop()
        reader.cancel()
        _ = await reader.value
        await supervisor.disconnect()
        await connection.close()
    }
}
