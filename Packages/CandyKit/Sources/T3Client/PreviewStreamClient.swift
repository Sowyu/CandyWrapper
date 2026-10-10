import Foundation
import ImageIO
import T3Protocol

/// One viewer of a server browser tab (`createPreviewStreamClient` plus `createPreviewFramePainter`,
/// packages/client-runtime/src/preview/serverBrowserStream.ts). It acks every JPEG frame at once,
/// decodes off the main thread one frame at a time and keeps only the newest waiting one, so a slow
/// viewer drops frames instead of queueing them. JSON messages arrive decoded on the main actor.
/// It reconnects with T3's backoff and stops for good on 4404, 4503 and a refused upgrade.
@MainActor
public final class PreviewStreamClient {
    public struct Events {
        public var onFrame: @MainActor (CGImage) -> Void = { _ in }
        public var onMessage: @MainActor (PreviewStream.Message) -> Void = { _ in }
        public var onConnectedChange: @MainActor (Bool) -> Void = { _ in }
        /// The upgrade was refused; the owner fetches a new ticket and starts a new client.
        public var onUnauthorized: @MainActor () -> Void = {}
        public var onGone: @MainActor () -> Void = {}
        public var onHostSetup: @MainActor (PreviewStream.HostSetup) -> Void = { _ in }
        public init() {}
    }

    private let url: @Sendable () async throws -> URL
    private let events: Events
    private var task: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var stopped = false
    /// The latest `control`; input other than `takeControl` needs `you` (the reference `send`).
    public private(set) var control: PreviewStream.Control?
    private let decoder = FrameDecoder()

    /// `url` runs before every connection attempt, so each gets a fresh ticket.
    public init(url: @escaping @Sendable () async throws -> URL, events: Events) {
        self.url = url
        self.events = events
    }

    public func start() {
        guard task == nil, !stopped else { return }
        decoder.deliver = { [weak self] image in self?.events.onFrame(image) }
        task = Task { [weak self] in await self?.run() }
    }

    public func stop() {
        stopped = true
        task?.cancel()
        task = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
        socket = nil
        session = nil
        control = nil
        decoder.stop()
    }

    /// False when the socket is closed or this viewer may not send it, and the input was dropped.
    @discardableResult
    public func send(_ input: PreviewStream.Input) -> Bool {
        guard let socket, let control, control.canOperate else { return false }
        if !input.isTakeControl, control.controller != .you { return false }
        socket.send(.string(input.encoded)) { _ in }
        return true
    }

    private func run() async {
        var failures = 0
        while !stopped, !Task.isCancelled {
            let target: URL
            do { target = try await url() } catch {
                if stopped { return }
                try? await Task.sleep(for: PreviewStream.retryDelay(failures: failures))
                failures += 1
                continue
            }
            let delegate = SocketDelegate()
            let config = URLSessionConfiguration.ephemeral
            config.httpShouldSetCookies = false
            config.httpCookieAcceptPolicy = .never
            config.timeoutIntervalForRequest = 7 * 24 * 3600
            let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
            let socket = session.webSocketTask(with: target)
            socket.maximumMessageSize = 32 * 1024 * 1024
            self.session = session
            self.socket = socket
            socket.resume()
            var announced = false
            do {
                while !stopped {
                    let message = try await socket.receive()
                    if !announced, delegate.isOpen { announced = true; events.onConnectedChange(true) }
                    switch message {
                    case .data(let jpeg):
                        failures = 0
                        socket.send(.string(PreviewStream.ack)) { _ in }
                        decoder.paint(jpeg)
                    case .string(let text):
                        guard let decoded = PreviewStream.Message.decode(text) else { continue }
                        if case .viewport = decoded { failures = 0 }
                        if case .control(let c) = decoded { control = c }
                        events.onMessage(decoded)
                    @unknown default: continue
                    }
                }
            } catch {}
            let opened = delegate.isOpen
            let (code, reason) = delegate.close ?? (opened ? 1006 : (delegate.httpStatus == nil ? 1006 : 1008), "")
            session.invalidateAndCancel()
            if self.socket === socket { self.socket = nil; self.session = nil }
            control = nil
            if announced || opened { events.onConnectedChange(false) }
            if stopped || Task.isCancelled { return }
            switch PreviewStream.closeOutcome(code: code, reason: reason, opened: opened) {
            case .gone: stopped = true; events.onGone(); return
            case .hostSetup(let setup): stopped = true; events.onHostSetup(setup); return
            case .unauthorized: stopped = true; events.onUnauthorized(); return
            case .retry:
                try? await Task.sleep(for: PreviewStream.retryDelay(failures: failures))
                failures += 1
            }
        }
    }

    private final class SocketDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var opened = false
        private var closeInfo: (Int, String)?
        private var status: Int?
        var isOpen: Bool { lock.withLock { opened } }
        var close: (Int, String)? { lock.withLock { closeInfo } }
        var httpStatus: Int? { lock.withLock { status } }

        func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
            lock.withLock { opened = true }
        }

        func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
            let text = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            lock.withLock { closeInfo = (closeCode.rawValue, text) }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            let code = (task.response as? HTTPURLResponse)?.statusCode
            lock.withLock {
                if let code, code != 101 { status = code }
                // A server close frame can arrive without `didCloseWith`; the task keeps the code.
                if closeInfo == nil, let ws = task as? URLSessionWebSocketTask, ws.closeCode != .invalid {
                    closeInfo = (ws.closeCode.rawValue, ws.closeReason.flatMap { String(data: $0, encoding: .utf8) } ?? "")
                }
            }
        }
    }
}

/// `createPreviewFramePainter` off the main thread: one decode at a time on a utility queue; a frame
/// that arrives meanwhile replaces the one waiting. ImageIO decodes into a bitmap here so the layer
/// draws it without decoding on the main thread.
final class FrameDecoder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.candywrapper.preview-frames", qos: .userInitiated)
    private let lock = NSLock()
    private var decoding = false
    private var waiting: Data?
    private var stopped = false
    @MainActor var deliver: (@MainActor (CGImage) -> Void)?

    func paint(_ jpeg: Data) {
        let start: Bool = lock.withLock {
            if stopped { return false }
            if decoding { waiting = jpeg; return false }
            decoding = true
            return true
        }
        if start { queue.async { self.decode(jpeg) } }
    }

    func stop() { lock.withLock { stopped = true; waiting = nil } }

    private func decode(_ jpeg: Data) {
        // A frame that fails to decode is skipped; the next one repaints.
        if let image = Self.image(jpeg) {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard !self.lock.withLock({ self.stopped }) else { return }
                    self.deliver?(image)
                }
            }
        }
        let next: Data? = lock.withLock {
            let n = stopped ? nil : waiting
            waiting = nil
            if n == nil { decoding = false }
            return n
        }
        if let next { decode(next) }
    }

    static func image(_ jpeg: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
}
