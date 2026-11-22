import Foundation

/// Downloads a media URL to a temporary file in chunks, reporting progress as bytes arrive. In Debug builds with
/// `CANDY_SLOW_LINK=<rtt ms>:<Mbit/s>` every transfer shares one simulated link: a request waits one round trip for
/// its first byte, and each chunk holds the link for its share of the bandwidth before the task reads on, so parallel
/// downloads split the rate the way TCP streams on one remote link do.
///
/// A transfer that stops moving gives up, so it can't hold one of `MediaFetchQueue`'s two slots: no bytes for
/// `idleTimeout`, or fewer than `minimumBytes` over a `stallWindow`, which catches a link that trickles a few bytes now
/// and then and so never hits the idle timeout. A stalled transfer is tried once more on a new request. The window
/// check is one sleep per running transfer, so nothing wakes while no transfer runs; it reads the task's byte count
/// because URLSession holds back the response and the first body bytes until it has 512 of them.
final class MediaTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = MediaTransfer()

    let stallWindow: Duration
    let minimumBytes: Int64
    /// Attempts per download when the earlier ones stalled.
    static let attempts = 2

    struct Result: Sendable {
        let file: URL
        let response: HTTPURLResponse
    }

    private final class State {
        let file: URL
        var handle: FileHandle?
        var received: Int64 = 0
        var expected: Int64 = -1
        var response: HTTPURLResponse?
        /// Set under the lock by the stall check before it cancels the task.
        var stalled = false
        var watchdog: Task<Void, Never>?
        let progress: (@Sendable (_ received: Int64, _ expected: Int64) -> Void)?
        let done: CheckedContinuation<Outcome, Never>
        init(file: URL, progress: (@Sendable (Int64, Int64) -> Void)?, done: CheckedContinuation<Outcome, Never>) {
            self.file = file; self.progress = progress; self.done = done
        }
    }

    private enum Outcome { case done(Result), stalled, failed }

    private let lock = NSLock()
    private var states: [Int: State] = [:]
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "MediaTransfer"
        q.maxConcurrentOperationCount = 1
        return q
    }()
    /// Made once in `init`. A `lazy var` is not thread safe: two first downloads at once built two sessions, whose task
    /// ids both start at 1, so two transfers shared one entry in `states` and one caller waited forever.
    private var session: URLSession!

    private let temporaryDirectory: URL

    /// `idleTimeout`: seconds with no bytes before URLSession fails the request, 60 by default. 15 s matches T3's
    /// socket liveness limit (client-runtime rpc/protocol.ts:10-12). 16 KiB in 15 s is under 9 kbit/s, far below any
    /// link that can show a picture.
    init(config: URLSessionConfiguration = .default, temporaryDirectory: URL = FileManager.default.temporaryDirectory,
         idleTimeout: TimeInterval = 15, stallWindow: Duration = .seconds(15), minimumBytes: Int64 = 16 * 1024) {
        self.temporaryDirectory = temporaryDirectory
        self.stallWindow = stallWindow
        self.minimumBytes = minimumBytes
        super.init()
        config.timeoutIntervalForRequest = idleTimeout
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpShouldSetCookies = false
        session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }

    /// The file, or nil on failure, a non-2xx answer or cancellation. The caller owns the file.
    func download(_ url: URL, method: String = "GET", progress: (@Sendable (_ received: Int64, _ expected: Int64) -> Void)? = nil) async -> Result? {
        for attempt in 1...Self.attempts {
            switch await transfer(url, method: method, progress: progress) {
            case .done(let result): return result
            case .failed: return nil
            case .stalled:
                ImageTiming.mark("transfer-stalled", "\(attempt) \(url.lastPathComponent)")
                if Task.isCancelled { return nil }
            }
        }
        return nil
    }

    private func transfer(_ url: URL, method: String, progress: (@Sendable (Int64, Int64) -> Void)?) async -> Outcome {
        guard !Task.isCancelled else { return .failed }
        await SlowLink.roundTrip()
        guard !Task.isCancelled else { return .failed }
        var request = URLRequest(url: url)
        request.httpMethod = method
        let file = temporaryDirectory.appendingPathComponent("cw-media-" + UUID().uuidString)
        let task = session.dataTask(with: request)
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { (done: CheckedContinuation<Outcome, Never>) in
                let early = lock.withLock {
                    if Task.isCancelled { return true }
                    states[task.taskIdentifier] = State(file: file, progress: progress, done: done)
                    return false
                }
                ImageTiming.mark("transfer-start", "\(task.taskIdentifier) early \(early) \(url.lastPathComponent)")
                if early { done.resume(returning: .failed) } else { task.resume(); watchForStall(task) }
            }
        } onCancel: {
            task.cancel()
            // A response or data callback can still be using the file handle.
            queue.addOperation { self.end(task.taskIdentifier, error: CancellationError()) }
        }
        if Task.isCancelled, case .done(let finished) = result {
            try? FileManager.default.removeItem(at: finished.file)
            return .failed
        }
        return result
    }

    /// Cancels `task` as stalled when a window passes with fewer than `minimumBytes`. Ends with the task.
    private func watchForStall(_ task: URLSessionDataTask) {
        let window = stallWindow, minimum = minimumBytes
        let watchdog = Task.detached(priority: .utility) { [weak self] in
            var last: Int64 = 0
            while true {
                do { try await Task.sleep(for: window) } catch { return }
                guard let self, task.state == .running || task.state == .suspended else { return }
                let received = task.countOfBytesReceived
                // The simulated slow link suspends tasks between chunks; only a running task is judged.
                if task.state == .running, received - last < minimum {
                    let watched = self.lock.withLock { () -> Bool in
                        guard let state = self.states[task.taskIdentifier] else { return false }
                        state.stalled = true
                        return true
                    }
                    if watched { task.cancel() }
                    return
                }
                last = received
            }
        }
        // A transfer that already ended has no state left, and its watchdog stops here.
        let owned = lock.withLock { () -> Bool in
            guard let state = states[task.taskIdentifier] else { return false }
            state.watchdog = watchdog
            return true
        }
        if !owned { watchdog.cancel() }
    }

    func invalidate() { session.invalidateAndCancel() }

    private func state(_ task: URLSessionTask) -> State? { lock.withLock { states[task.taskIdentifier] } }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let state = state(dataTask), let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              FileManager.default.createFile(atPath: state.file.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: state.file) else {
            completionHandler(.cancel)
            return
        }
        ImageTiming.mark("transfer-response", "\(dataTask.taskIdentifier) \(http.statusCode) \(http.expectedContentLength)")
        state.response = http
        state.handle = handle
        state.expected = http.expectedContentLength
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let state = state(dataTask), let handle = state.handle else { return }
        do { try handle.write(contentsOf: data) } catch { dataTask.cancel(); return }
        state.received += Int64(data.count)
        state.progress?(state.received, state.expected)
        // The simulated link: stop reading until this chunk's share of the link has passed.
        let wait = SlowLink.reserve(bytes: data.count)
        if wait > 0.002 {
            dataTask.suspend()
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + wait) { dataTask.resume() }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        ImageTiming.mark("transfer-end", "\(task.taskIdentifier) \(error.map { "\($0)" } ?? "ok")")
        end(task.taskIdentifier, error: error)
    }

    private func end(_ id: Int, error: Error?) {
        guard let state = lock.withLock({ states.removeValue(forKey: id) }) else { return }
        state.watchdog?.cancel()
        try? state.handle?.close()
        if error == nil, let response = state.response {
            state.done.resume(returning: .done(Result(file: state.file, response: response)))
        } else {
            try? FileManager.default.removeItem(at: state.file)
            // Cancellation by the caller ends with CancellationError; a stall cancels the task itself.
            let stalled = !(error is CancellationError) && (lock.withLock { state.stalled } || (error as? URLError)?.code == .timedOut)
            state.done.resume(returning: stalled ? .stalled : .failed)
        }
    }
}

/// Development only: `CANDY_SLOW_LINK=<rtt ms>:<Mbit/s>` stands in for a remote environment or the T3 Connect relay
/// on loopback. Release builds ignore the variable.
enum SlowLink {
    struct Link: Equatable { let rtt: Double; let mbps: Double }

    static func parse(_ environment: [String: String]) -> Link? {
        guard let raw = environment["CANDY_SLOW_LINK"] else { return nil }
        let parts = raw.split(separator: ":").compactMap { Double($0) }
        return parts.count == 2 && parts[0] >= 0 && parts[1] > 0 ? Link(rtt: parts[0], mbps: parts[1]) : nil
    }

    static let link: Link? = {
        #if DEBUG
        parse(ProcessInfo.processInfo.environment)
        #else
        nil
        #endif
    }()

    private static let lock = NSLock()
    nonisolated(unsafe) private static var busyUntil = Date.distantPast

    /// One round trip, for a request's first byte or an RPC call.
    static func roundTrip() async {
        guard let link else { return }
        try? await Task.sleep(for: .milliseconds(link.rtt))
    }

    /// Seconds until `bytes` have crossed the link behind what other transfers already queued on it.
    static func reserve(bytes: Int) -> TimeInterval {
        guard let link else { return 0 }
        let transfer = Double(bytes) * 8 / (link.mbps * 1_000_000)
        return lock.withLock {
            let now = Date()
            busyUntil = max(busyUntil, now).addingTimeInterval(transfer)
            return busyUntil.timeIntervalSince(now)
        }
    }
}
