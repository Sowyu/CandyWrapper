import Foundation

/// The text-frame socket RPCConnection runs on. URLSessionRPCSocket in the app, a fake in tests.
public protocol RPCSocket: Sendable {
    func send(_ frame: Data) async throws
    /// The next text frame. Throws once the socket is closed or failed.
    func receive() async throws -> Data
    func close()
}

public enum RPCTransportError: Error, Sendable, Equatable, CustomStringConvertible {
    case openTimedOut
    /// The HTTP upgrade was answered with a status instead of 101 (401 bad ticket, 426 protocol).
    case upgradeRejected(status: Int)
    case closed(String)
    case pingTimedOut
    case invalidFrame(String)

    public var description: String {
        switch self {
        case .openTimedOut: "The WebSocket did not open in time."
        case .upgradeRejected(let s): "The server rejected the WebSocket upgrade with HTTP \(s)."
        case .closed(let r): "Disconnected: \(r)"
        // An open socket that went quiet points at the host, not the network (client-runtime/src/rpc/session.ts:194-200).
        case .pingTimedOut: "The server stopped responding for 15s. \(unresponsiveHostHint)"
        case .invalidFrame(let r): "The server sent a frame this client can't read: \(r)"
        }
    }
}

/// URLSessionWebSocketTask behind RPCSocket. One URLSession per socket so the delegate can
/// report the open, the close and the upgrade status for exactly this task.
public final class URLSessionRPCSocket: RPCSocket {
    private let task: URLSessionWebSocketTask
    private let session: URLSession
    private let delegate: Delegate

    /// Opens the socket and waits for the upgrade. `openTimeout` matches T3's SOCKET_OPEN_TIMEOUT.
    public static func open(url: URL, openTimeout: Duration = .seconds(15)) async throws -> URLSessionRPCSocket {
        let socket = URLSessionRPCSocket(url: url)
        do {
            try await withTimeout(openTimeout, error: RPCTransportError.openTimedOut) {
                try await socket.delegate.waitForOpen()
            }
        } catch {
            socket.close()
            throw error
        }
        return socket
    }

    private init(url: URL) {
        let config = URLSessionConfiguration.ephemeral
        // A cookie beats the Authorization header on the server (protocol.md 4.2). No cookies.
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpCookieStorage = nil
        // URLSession applies timeoutIntervalForRequest as an idle timeout on WebSocket tasks,
        // which would drop a quiet socket after 60 s. The open timeout above replaces it.
        config.timeoutIntervalForRequest = 7 * 24 * 3600
        config.timeoutIntervalForResource = 365 * 24 * 3600
        delegate = Delegate()
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        var request = URLRequest(url: url)
        request.timeoutInterval = config.timeoutIntervalForRequest
        task = session.webSocketTask(with: request)
        // Snapshots can be several MiB. The server's `ws` limit is 100 MiB (unverified).
        task.maximumMessageSize = 100 * 1024 * 1024
        task.resume()
    }

    public func send(_ frame: Data) async throws {
        // Text frames: the server's JSON serialization reads strings.
        try await task.send(.string(String(decoding: frame, as: UTF8.self)))
    }

    public func receive() async throws -> Data {
        do {
            switch try await task.receive() {
            case .string(let s): return Data(s.utf8)
            case .data(let d): return d
            @unknown default: throw RPCTransportError.invalidFrame("unknown message kind")
            }
        } catch let e as RPCTransportError {
            throw e
        } catch {
            throw RPCTransportError.closed(delegate.closeDescription ?? error.localizedDescription)
        }
    }

    public func close() {
        task.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }

    private final class Delegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
        // Guards the fields below; delegate callbacks arrive on URLSession's queue.
        private let lock = NSLock()
        private var opened = false
        private var failure: Error?
        private var waiter: CheckedContinuation<Void, Error>?
        private var closeText: String?

        var closeDescription: String? { lock.withLock { closeText } }

        func waitForOpen() async throws {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                    let result: Result<Void, Error>? = lock.withLock {
                        if opened { return .success(()) }
                        if let failure { return .failure(failure) }
                        waiter = c
                        return nil
                    }
                    if let result { c.resume(with: result) }
                }
            } onCancel: {
                finishOpen(.failure(CancellationError()))
            }
        }

        private func finishOpen(_ result: Result<Void, Error>) {
            let w: CheckedContinuation<Void, Error>? = lock.withLock {
                switch result {
                case .success: opened = true
                case .failure(let e): if !opened { failure = e }
                }
                defer { waiter = nil }
                return waiter
            }
            w?.resume(with: result)
        }

        func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
            finishOpen(.success(()))
        }

        func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
            let text = "close code \(closeCode.rawValue)" + (reason.flatMap { String(data: $0, encoding: .utf8) }.map { ", \($0)" } ?? "")
            lock.withLock { closeText = text }
            finishOpen(.failure(RPCTransportError.closed(text)))
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let http = task.response as? HTTPURLResponse, http.statusCode != 101 {
                finishOpen(.failure(RPCTransportError.upgradeRejected(status: http.statusCode)))
            } else {
                finishOpen(.failure(RPCTransportError.closed(error?.localizedDescription ?? "socket closed")))
            }
        }
    }
}

/// Runs `body`, throwing `error` if it takes longer than `timeout`. The body is cancelled on timeout.
func withTimeout<T: Sendable>(_ timeout: Duration, error: Error = CancellationError(),
                              _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw error
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
