import Foundation
import Network
import Testing
@testable import Features

/// A transfer that stops moving gives its fetch slot back: a server that trickles a byte now and then never hits
/// URLSession's idle timeout, so it is caught by the bytes-per-window check, and one that goes silent by the idle
/// timeout. Each stalled transfer is tried once more, then fails.
@Suite(.serialized)
struct MediaTransferStallTests {
    /// One-route HTTP server on loopback. `body` writes the response after the request arrives.
    final class Server: @unchecked Sendable {
        enum Mode { case trickle, silent, whole(Int) }
        private let listener: NWListener
        private let lock = NSLock()
        private var count = 0
        private var open: [NWConnection] = []
        var connections: Int { lock.withLock { count } }
        private(set) var port: UInt16 = 0

        init(_ mode: Mode) async throws {
            listener = try NWListener(using: .tcp, on: .any)
            let ready = AsyncStream<UInt16>.makeStream()
            listener.stateUpdateHandler = { [listener] state in
                if case .ready = state, let port = listener.port?.rawValue { ready.continuation.yield(port); ready.continuation.finish() }
            }
            let queue = DispatchQueue(label: "MediaTransferStallTests")
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                lock.withLock { count += 1; open.append(connection) }
                connection.start(queue: queue)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in
                    Self.answer(connection, mode, queue: queue)
                }
            }
            listener.start(queue: queue)
            var port: UInt16 = 0
            for await p in ready.stream { port = p }
            self.port = port
        }

        private static func answer(_ connection: NWConnection, _ mode: Mode, queue: DispatchQueue) {
            let length: Int
            if case .whole(let n) = mode { length = n } else { length = 1_000_000 }
            let head = "HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: \(length)\r\n\r\n"
            connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
            switch mode {
            case .whole(let n): connection.send(content: Data(repeating: 7, count: n), completion: .contentProcessed { _ in })
            case .silent: break
            case .trickle:
                func drip() {
                    queue.asyncAfter(deadline: .now() + 0.05) {
                        guard connection.state == .ready else { return }
                        connection.send(content: Data([7]), completion: .contentProcessed { error in if error == nil { drip() } })
                    }
                }
                drip()
            }
        }

        var url: URL { URL(string: "http://127.0.0.1:\(port)/picture.png")! }

        func stop() {
            listener.cancel()
            lock.withLock { open }.forEach { $0.cancel() }
        }
    }

    /// The download's result, or nil when it didn't finish within `limit`: the slot would still be held.
    private func download(_ transfer: MediaTransfer, _ url: URL, limit: Duration = .seconds(8)) async -> MediaTransfer.Result?? {
        await withTaskGroup(of: MediaTransfer.Result??.self) { group in
            group.addTask { .some(await transfer.download(url)) }
            group.addTask { try? await Task.sleep(for: limit); return .none }
            defer { group.cancelAll() }
            return await group.next()!
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func aTricklingTransferGivesUpAndRetriesOnce() async throws {
        let server = try await Server(.trickle)
        defer { server.stop() }
        let transfer = MediaTransfer(idleTimeout: 30, stallWindow: .milliseconds(300), minimumBytes: 1024)
        let outcome = await download(transfer, server.url)
        let finished = try #require(outcome, "a trickling transfer kept its slot")
        #expect(finished == nil)
        #expect(server.connections == MediaTransfer.attempts)
    }

    @Test(.timeLimit(.minutes(1)))
    func aSilentTransferTimesOutAndRetriesOnce() async throws {
        let server = try await Server(.silent)
        defer { server.stop() }
        let transfer = MediaTransfer(idleTimeout: 1, stallWindow: .seconds(30), minimumBytes: 1024)
        let outcome = await download(transfer, server.url)
        let finished = try #require(outcome, "a silent transfer kept its slot")
        #expect(finished == nil)
        #expect(server.connections == MediaTransfer.attempts)
    }

    @Test(.timeLimit(.minutes(1)))
    func aHealthyTransferIsNotRetried() async throws {
        let server = try await Server(.whole(200_000))
        defer { server.stop() }
        let transfer = MediaTransfer(idleTimeout: 1, stallWindow: .milliseconds(300), minimumBytes: 1024)
        let outcome = await download(transfer, server.url)
        let finished = try #require(outcome)
        let result = try #require(finished)
        defer { try? FileManager.default.removeItem(at: result.file) }
        #expect(try Data(contentsOf: result.file).count == 200_000)
        #expect(server.connections == 1)
    }
}
