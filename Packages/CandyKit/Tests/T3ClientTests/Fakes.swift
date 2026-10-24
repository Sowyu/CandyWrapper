import Foundation
@testable import T3Client
@testable import T3Transport
import T3Protocol

/// In-memory RPCSocket. The test plays the server.
final class FakeSocket: RPCSocket, @unchecked Sendable {
    // NSLock guards everything below.
    private let lock = NSLock()
    private var inbound: [Data] = []
    private var receiver: CheckedContinuation<Data, Error>?
    private var closed = false
    private var sentFrames: [RPCClientMessage] = []
    private var sendFails = false

    var sent: [RPCClientMessage] { lock.withLock { sentFrames } }
    var isClosed: Bool { lock.withLock { closed } }
    /// Makes the next `send` throw, like a socket the network dropped.
    func failNextSend() { lock.withLock { sendFails = true } }

    func send(_ frame: Data) async throws {
        let messages = try RPCFrame.decodeClient(frame)
        try lock.withLock {
            if closed { throw RPCTransportError.closed("fake closed") }
            if sendFails { sendFails = false; throw URLError(.networkConnectionLost) }
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
        deliverRaw(try! RPCFrame.encode(message))
    }

    /// Server side: deliver bytes as one frame, valid or not.
    func deliverRaw(_ data: Data) {
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

/// Polls until `condition` holds or `seconds` pass. Use it only for things that will happen; the
/// long cap keeps a busy machine from failing it.
func eventually(seconds: Int = 30, _ condition: @Sendable () async -> Bool) async -> Bool {
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

/// A `SleepClock` the test steps by hand. Sleepers wake only in `advance(by:)`.
final class ManualClock: @unchecked Sendable {
    // NSLock guards everything below.
    private let lock = NSLock()
    private let start = ContinuousClock.now
    private var offset: Duration = .zero
    private var sleepers: [Int: (deadline: Duration, continuation: CheckedContinuation<Void, Error>)] = [:]
    private var cancelled: Set<Int> = []
    private var nextID = 0
    private var started = 0

    var clock: SleepClock { SleepClock(now: { self.now }, sleep: { duration, _ in try await self.sleep(duration) }) }
    var now: ContinuousClock.Instant { lock.withLock { start + offset } }
    /// Sleeps begun so far, woken or not.
    var sleepCount: Int { lock.withLock { started } }
    /// Sleeps waiting for `advance`.
    var waiting: Int { lock.withLock { sleepers.count } }

    func sleep(_ duration: Duration) async throws {
        let id: Int = lock.withLock { nextID += 1; started += 1; return nextID }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                let result: Result<Void, Error>? = lock.withLock {
                    if cancelled.remove(id) != nil { return .failure(CancellationError()) }
                    if duration <= .zero { return .success(()) }
                    sleepers[id] = (offset + duration, c)
                    return nil
                }
                if let result { c.resume(with: result) }
            }
        } onCancel: {
            let c: CheckedContinuation<Void, Error>? = lock.withLock {
                guard let s = sleepers.removeValue(forKey: id) else { cancelled.insert(id); return nil }
                return s.continuation
            }
            c?.resume(throwing: CancellationError())
        }
    }

    /// Moves time forward and wakes every sleeper that is due.
    func advance(by duration: Duration) {
        let due: [CheckedContinuation<Void, Error>] = lock.withLock {
            offset += duration
            let ready = sleepers.filter { $0.value.deadline <= offset }
            for id in ready.keys { sleepers[id] = nil }
            return ready.values.map(\.continuation)
        }
        due.forEach { $0.resume() }
    }
}
