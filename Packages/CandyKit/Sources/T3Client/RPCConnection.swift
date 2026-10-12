import Foundation
import T3Protocol

/// Why an RPC call failed.
public enum RPCClientError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The server answered with `Exit` `Failure`.
    case failure([RPCCause])
    /// A connection-level `Defect` frame. Every pending call fails with it; the socket stays open.
    case defect(JSONValue)
    case protocolError(JSONValue)
    /// The socket closed or failed. Every pending call and stream fails with this.
    case transport(RPCTransportError)

    /// The declared error from the first `Fail` cause, if any.
    public var typedError: RPCTypedError? {
        guard case .failure(let causes) = self else { return nil }
        for case .fail(let e) in causes { return e }
        return nil
    }

    public var isTransport: Bool { if case .transport = self { return true }; return false }

    public var description: String {
        switch self {
        case .failure(let causes):
            if let e = typedError { return e.message ?? e.tag }
            for case .die(let d) in causes { return d.stringValue ?? "Request failed." }
            return "Request was interrupted."
        case .defect(let d): return d.stringValue ?? "Server defect."
        case .protocolError: return "Client protocol error."
        case .transport(let t): return t.description
        }
    }
}

/// One Effect RPC session over one socket (protocol.md 2.3 to 2.6).
///
/// Frames are decoded on a detached task, so neither the main thread nor this actor parses JSON.
/// Writes go through one ordered outbox so an `Ack` never blocks the consumer that caused it.
public actor RPCConnection {
    private let socket: any RPCSocket
    private var nextID = 1
    private var unary: [RPCRequestID: CheckedContinuation<JSONValue, Error>] = [:]
    private var streams: [RPCRequestID: StreamState] = [:]
    private var pongWaiters: [Int: CheckedContinuation<Void, Error>] = [:]
    private var nextPongWaiter = 0
    private var closeWaiters: [CheckedContinuation<RPCClientError, Never>] = []
    private var closedWith: RPCClientError?
    private var receiveTask: Task<Void, Never>?
    private var writeTask: Task<Void, Never>?
    private let outbox: AsyncStream<Data>.Continuation
    private let outboxStream: AsyncStream<Data>
    /// Liveness while a reply is owed. Effect's client pings every 5 s and drops a socket whose
    /// Pong misses the next tick (makePinger, effect-smol RpcClient.ts:1205-1227). CandyWrapper
    /// sends no idle pings (see `ConnectionSupervisor`), so a socket that dies without a close it
    /// can see would wedge every call and stream for good: a peer that half-closes in the middle
    /// of a frame leaves URLSession's `receive()` waiting forever. So while a unary call or a
    /// stream's first answer is outstanding, `livenessInterval` without any inbound frame sends
    /// a Ping, and a Pong still missing after another interval closes the socket, which makes the
    /// supervisor reconnect. Nothing runs while nothing is owed.
    private let livenessInterval: Duration
    private var lastInbound = ContinuousClock.now
    private var watchdog: Task<Void, Never>?

    public init(socket: any RPCSocket, livenessInterval: Duration = .seconds(5)) {
        self.socket = socket
        self.livenessInterval = livenessInterval
        (outboxStream, outbox) = AsyncStream<Data>.makeStream()
    }

    /// Starts reading and writing. Call once, before the first request.
    public func start() {
        guard receiveTask == nil else { return }
        let socket = socket
        receiveTask = Task.detached { [weak self] in
            while true {
                let messages: [RPCServerMessage]
                do {
                    let frame = try await socket.receive()
                    if OpenTiming.active {
                        // The socket hands over whole messages: first and last byte arrive before this line.
                        OpenTiming.mark("frame received", "\(frame.count) bytes")
                        messages = try OpenTiming.measure("frame parsed", "\(frame.count) bytes") { try RPCFrame.decodeServer(frame) }
                    } else {
                        messages = try RPCFrame.decodeServer(frame)
                    }
                } catch let e as RPCTransportError {
                    await self?.shutDown(.transport(e))
                    return
                } catch is DecodingError {
                    await self?.shutDown(.transport(.invalidFrame("undecodable frame")))
                    return
                } catch {
                    await self?.shutDown(.transport(.closed(error.localizedDescription)))
                    return
                }
                PerfCounters.received(messages.count)
                guard let self else { return }
                await self.handle(messages)
            }
        }
        let frames = outboxStream
        writeTask = Task.detached { [weak self] in
            for await frame in frames {
                do { try await socket.send(frame) } catch {
                    await self?.shutDown(.transport(.closed("send failed: \(error.localizedDescription)")))
                    return
                }
            }
        }
    }

    // MARK: Public API

    /// Unary call. Throws `RPCClientError`, or `CancellationError` after sending `Interrupt`.
    public func request(_ tag: String, payload: JSONValue = .object([:])) async throws -> JSONValue {
        let id = allocateID()
        let latencyID = UUID()
        await SlowRPCRequestTracker.shared.start(id: latencyID, method: tag)
        defer { Task { await SlowRPCRequestTracker.shared.finish(id: latencyID) } }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<JSONValue, Error>) in
                if let closedWith { return c.resume(throwing: closedWith) }
                if Task.isCancelled { return c.resume(throwing: CancellationError()) }
                unary[id] = c
                write(.request(RPCRequest(id: id, tag: tag, payload: payload)))
                armWatchdog()
                OpenTiming.mark("request sent", tag)
            }
        } onCancel: {
            Task { await self.cancelUnary(id) }
        }
    }

    /// Streaming call. The request goes out now; values arrive as the consumer pulls them.
    /// Each `Chunk` is acked once its last value has been handed to the consumer, so the server
    /// never runs more than one chunk ahead (protocol.md 2.4). Cancelling the consuming task,
    /// or dropping the stream, sends `Interrupt`.
    public func stream(_ tag: String, payload: JSONValue = .object([:])) -> RPCStream {
        let id = allocateID()
        if let closedWith {
            let state = StreamState()
            state.end = .failure(closedWith)
            streams[id] = state
        } else {
            streams[id] = StreamState()
            write(.request(RPCRequest(id: id, tag: tag, payload: payload)))
            armWatchdog()
            OpenTiming.mark("request sent", tag)
        }
        return RPCStream(handle: StreamHandle(id: id, connection: self))
    }

    /// Sends `Ping` and waits for `Pong`.
    public func ping(timeout: Duration) async throws {
        try await withTimeout(timeout, error: RPCTransportError.pingTimedOut) { [self] in
            try await awaitPong()
        }
    }

    /// Closes the socket. Every pending call and stream fails with a transport error.
    public func close(reason: String = "closed by client") {
        shutDown(.transport(.closed(reason)))
    }

    public var isClosed: Bool { closedWith != nil }

    /// Returns when the connection is closed, with the reason.
    public func waitUntilClosed() async -> RPCClientError {
        if let closedWith { return closedWith }
        return await withCheckedContinuation { closeWaiters.append($0) }
    }

    // MARK: Internals

    private func allocateID() -> RPCRequestID {
        defer { nextID += 1 }
        return .string(String(nextID))
    }

    private func write(_ message: RPCClientMessage) {
        guard closedWith == nil, let data = try? RPCFrame.encode(message) else { return }
        outbox.yield(data)
    }

    private func awaitPong() async throws {
        nextPongWaiter += 1
        let key = nextPongWaiter
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                if let closedWith { return c.resume(throwing: closedWith) }
                if Task.isCancelled { return c.resume(throwing: CancellationError()) }
                pongWaiters[key] = c
                write(.ping)
            }
        } onCancel: {
            Task { await self.cancelPong(key) }
        }
    }

    private func cancelPong(_ key: Int) {
        pongWaiters.removeValue(forKey: key)?.resume(throwing: CancellationError())
    }

    private func cancelUnary(_ id: RPCRequestID) {
        guard let c = unary.removeValue(forKey: id) else { return }
        write(.interrupt(id))
        c.resume(throwing: CancellationError())
    }

    fileprivate func cancelStream(_ id: RPCRequestID) {
        guard let state = streams.removeValue(forKey: id) else { return }
        if state.end == nil { write(.interrupt(id)) }
        state.waiter?.resume(returning: nil)
        state.waiter = nil
    }

    fileprivate func nextValue(_ id: RPCRequestID) async throws -> JSONValue? {
        guard let state = streams[id] else { return nil }
        if let value = takeValue(id, state) { return value }
        if let end = state.end {
            streams[id] = nil
            if case .failure(let e) = end { throw e }
            return nil
        }
        if Task.isCancelled { cancelStream(id); return nil }
        return try await withCheckedThrowingContinuation { state.waiter = $0 }
    }

    /// Hands out the next buffered value and acks its chunk when it was the chunk's last.
    private func takeValue(_ id: RPCRequestID, _ state: StreamState) -> JSONValue? {
        guard state.head < state.buffer.count else { return nil }
        let value = state.buffer[state.head]
        state.head += 1
        if state.head == state.buffer.count {
            state.buffer.removeAll(keepingCapacity: true)
            state.head = 0
            if state.end == nil { write(.ack(id)) }
        }
        return value
    }

    private func handle(_ messages: [RPCServerMessage]) {
        lastInbound = ContinuousClock.now
        defer { if watchdog != nil, !owesReply { watchdog?.cancel(); watchdog = nil } }
        for message in messages {
            switch message {
            case .chunk(let id, let values):
                guard let state = streams[id], state.end == nil, !values.isEmpty else { continue }
                state.answered = true
                state.buffer.append(contentsOf: values)
                if let w = state.waiter {
                    state.waiter = nil
                    w.resume(returning: takeValue(id, state))
                }
            case .exit(let id, let exit):
                let result: Result<JSONValue, RPCClientError> = switch exit {
                case .success(let v): .success(v)
                case .failure(let causes): .failure(.failure(causes))
                }
                if let c = unary.removeValue(forKey: id) {
                    c.resume(with: result.mapError { $0 as Error })
                } else if let state = streams[id] {
                    finish(id, state, result.map { _ in () })
                }
            case .defect(let d):
                failPending(.defect(d))
            case .clientProtocolError(let e):
                failPending(.protocolError(e))
            case .pong:
                let waiters = pongWaiters.values
                pongWaiters.removeAll()
                waiters.forEach { $0.resume() }
            case .unknown:
                continue
            }
        }
    }

    // MARK: Liveness

    /// A unary call, or a stream that has had neither a chunk nor its exit yet.
    private var owesReply: Bool { !unary.isEmpty || streams.values.contains { !$0.answered && $0.end == nil } }

    private func armWatchdog() {
        guard watchdog == nil, closedWith == nil else { return }
        let interval = livenessInterval
        watchdog = Task { [weak self] in
            while true {
                do { try await Task.sleep(for: interval) } catch { return }
                guard let self, await self.livenessTick() else { return }
            }
        }
    }

    /// One watchdog step; false ends the watchdog. Pings only after a quiet interval, so a socket
    /// that keeps delivering frames, or a slow call on a live socket, costs one Ping per interval.
    private func livenessTick() async -> Bool {
        guard closedWith == nil, owesReply else { watchdog = nil; return false }
        guard ContinuousClock.now - lastInbound >= livenessInterval else { return true }
        do {
            try await ping(timeout: livenessInterval)
            // The socket works. A subscription that stays quiet (a terminal, a status feed) owes
            // nothing more, so only unary calls keep the watchdog going.
            for state in streams.values { state.answered = true }
            if owesReply { return true }
            watchdog = nil
            return false
        } catch RPCTransportError.pingTimedOut {
            watchdog = nil
            shutDown(.transport(.pingTimedOut))
            return false
        } catch {
            // Cancelled because the reply arrived, or the socket closed meanwhile.
            return false
        }
    }

    private func finish(_ id: RPCRequestID, _ state: StreamState, _ end: Result<Void, RPCClientError>) {
        guard state.end == nil else { return }
        state.end = end
        if let w = state.waiter, state.head >= state.buffer.count {
            state.waiter = nil
            streams[id] = nil
            switch end {
            case .success: w.resume(returning: nil)
            case .failure(let e): w.resume(throwing: e)
            }
        }
    }

    private func failPending(_ error: RPCClientError) {
        let calls = unary
        unary.removeAll()
        calls.values.forEach { $0.resume(throwing: error) }
        for (id, state) in streams { finish(id, state, .failure(error)) }
    }

    private func shutDown(_ error: RPCClientError) {
        guard closedWith == nil else { return }
        closedWith = error
        failPending(error)
        let pongs = pongWaiters.values
        pongWaiters.removeAll()
        pongs.forEach { $0.resume(throwing: error) }
        let waiters = closeWaiters
        closeWaiters.removeAll()
        waiters.forEach { $0.resume(returning: error) }
        outbox.finish()
        socket.close()
        receiveTask?.cancel()
        watchdog?.cancel()
        watchdog = nil
    }
}

/// Per-stream buffer. Only touched on the RPCConnection actor.
private final class StreamState {
    var buffer: [JSONValue] = []
    var head = 0
    var end: Result<Void, RPCClientError>?
    var waiter: CheckedContinuation<JSONValue?, Error>?
    /// A chunk arrived, so the server has answered the subscription.
    var answered = false
}

/// Interrupts the stream when the last reference goes away before the stream ended.
final class StreamHandle: Sendable {
    let id: RPCRequestID
    let connection: RPCConnection

    init(id: RPCRequestID, connection: RPCConnection) {
        self.id = id
        self.connection = connection
    }

    deinit {
        let id = id, connection = connection
        Task { await connection.cancelStream(id) }
    }
}

/// Values of one RPC stream. Single consumer.
public struct RPCStream: AsyncSequence, Sendable {
    public typealias Element = JSONValue
    let handle: StreamHandle

    public var requestID: RPCRequestID { handle.id }

    public func makeAsyncIterator() -> Iterator { Iterator(handle: handle) }

    public struct Iterator: AsyncIteratorProtocol, Sendable {
        let handle: StreamHandle

        public mutating func next() async throws -> JSONValue? {
            let handle = handle
            return try await withTaskCancellationHandler {
                try await handle.connection.nextValue(handle.id)
            } onCancel: {
                Task { await handle.connection.cancelStream(handle.id) }
            }
        }
    }

    /// Decodes each value as `T`.
    public func decoded<T: Decodable & Sendable>(as type: T.Type) -> AsyncThrowingMapSequence<RPCStream, T> {
        map { try $0.decode(as: T.self) }
    }
}

extension RPCConnection {
    /// Typed unary call.
    public func request<P: Encodable & Sendable, R: Decodable>(_ tag: String, _ payload: P, as: R.Type) async throws -> R {
        try await request(tag, payload: JSONValue(encoding: payload)).decode(as: R.self)
    }
}
