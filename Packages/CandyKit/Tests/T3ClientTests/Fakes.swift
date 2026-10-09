import Foundation
@testable import T3Client
import T3Protocol

/// In-memory RPCSocket. The test plays the server.
final class FakeSocket: RPCSocket, @unchecked Sendable {
    // NSLock guards everything below.
    private let lock = NSLock()
    private var inbound: [Data] = []
    private var receiver: CheckedContinuation<Data, Error>?
    private var closed = false
    private var sentFrames: [RPCClientMessage] = []

    var sent: [RPCClientMessage] { lock.withLock { sentFrames } }
    var isClosed: Bool { lock.withLock { closed } }

    func send(_ frame: Data) async throws {
        let messages = try RPCFrame.decodeClient(frame)
        try lock.withLock {
            if closed { throw RPCTransportError.closed("fake closed") }
            sentFrames.append(contentsOf: messages)
        }
    }

    func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { c in
            let result: Result<Data, Error>? = lock.withLock {
                if !inbound.isEmpty { return .success(inbound.removeFirst()) }
                if closed { return .failure(RPCTransportError.closed("fake closed")) }
                receiver = c
                return nil
            }
            if let result { c.resume(with: result) }
        }
    }

    func close() {
        let r: CheckedContinuation<Data, Error>? = lock.withLock {
            closed = true
            defer { receiver = nil }
            return receiver
        }
        r?.resume(throwing: RPCTransportError.closed("fake closed"))
    }

    /// Server side: deliver one frame.
    func deliver(_ message: RPCServerMessage) {
        let data = try! RPCFrame.encode(message)
        let r: CheckedContinuation<Data, Error>? = lock.withLock {
            if let receiver {
                self.receiver = nil
                return receiver
            }
            inbound.append(data)
            return nil
        }
        r?.resume(returning: data)
    }
}

/// Polls until `condition` holds or `seconds` pass.
func eventually(seconds: Int = 2, _ condition: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<(seconds * 200) {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return false
}

/// Settles pending tasks so "nothing was sent" checks mean something.
func settle() async {
    for _ in 0..<20 { await Task.yield() }
    try? await Task.sleep(for: .milliseconds(20))
}
