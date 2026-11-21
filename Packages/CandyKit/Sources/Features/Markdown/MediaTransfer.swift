import Foundation

/// Downloads a media URL to a temporary file in chunks, reporting progress as bytes arrive. In Debug builds with
/// `CANDY_SLOW_LINK=<rtt ms>:<Mbit/s>` every transfer shares one simulated link: a request waits one round trip for
/// its first byte, and each chunk holds the link for its share of the bandwidth before the task reads on, so parallel
/// downloads split the rate the way TCP streams on one remote link do.
final class MediaTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = MediaTransfer()

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
        let progress: (@Sendable (_ received: Int64, _ expected: Int64) -> Void)?
        let done: CheckedContinuation<Result?, Never>
        init(file: URL, progress: (@Sendable (Int64, Int64) -> Void)?, done: CheckedContinuation<Result?, Never>) {
            self.file = file; self.progress = progress; self.done = done
        }
    }

    private let lock = NSLock()
    private var states: [Int: State] = [:]
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "MediaTransfer"
        q.maxConcurrentOperationCount = 1
        return q
    }()
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpShouldSetCookies = false
        return URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }()

    /// The file, or nil on failure, a non-2xx answer or cancellation. The caller owns the file.
    func download(_ url: URL, method: String = "GET", progress: (@Sendable (_ received: Int64, _ expected: Int64) -> Void)? = nil) async -> Result? {
        guard !Task.isCancelled else { return nil }
        await SlowLink.roundTrip()
        guard !Task.isCancelled else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = method
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("cw-media-" + UUID().uuidString)
        let task = session.dataTask(with: request)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (done: CheckedContinuation<Result?, Never>) in
                lock.withLock { states[task.taskIdentifier] = State(file: file, progress: progress, done: done) }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private func state(_ task: URLSessionTask) -> State? { lock.withLock { states[task.taskIdentifier] } }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let state = state(dataTask), let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              FileManager.default.createFile(atPath: state.file.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: state.file) else {
            completionHandler(.cancel)
            return
        }
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
        guard let state = lock.withLock({ states.removeValue(forKey: task.taskIdentifier) }) else { return }
        try? state.handle?.close()
        if error == nil, let response = state.response {
            state.done.resume(returning: Result(file: state.file, response: response))
        } else {
            try? FileManager.default.removeItem(at: state.file)
            state.done.resume(returning: nil)
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
