import Foundation
import T3Transport

/// Rebuilds whole WebSocket messages from the pieces `curl_ws_recv` hands over. curl gives at most a buffer's worth of
/// a frame at a time with the bytes still to come (`bytesleft`), and marks every fragment but a message's last with
/// `CURLWS_CONT`. swift-corelibs-foundation's URLSessionWebSocketTask skips this step: it passes each curl write callback
/// (16 KB at most) on as a whole message (WebSocketURLProtocol.swift:101-180 at swift-6.4.1-RELEASE), so on Linux any
/// message over 16 KB, like a shell snapshot, arrived as pieces that didn't decode, and a text piece cut inside a
/// UTF-8 character failed the connection. That's what aniko hit on 2026-10-24.
struct WebSocketAssembler {
    /// curl's `CURLWS_*` flags (websockets.h), here so the assembler builds and tests without libcurl.
    static let text: Int32 = 1 << 0, binary: Int32 = 1 << 1, cont: Int32 = 1 << 2, close: Int32 = 1 << 3, ping: Int32 = 1 << 4, pong: Int32 = 1 << 6

    enum Event: Equatable { case message(Data), close }

    private var pending = Data()

    /// One piece; a whole message once its last byte arrived.
    mutating func feed(_ piece: Data, flags: Int32, bytesLeft: Int) -> Event? {
        if flags & Self.close != 0 { return bytesLeft == 0 ? .close : nil }
        // curl answers pings itself; neither pings nor pongs carry a message.
        if flags & (Self.ping | Self.pong) != 0 { return nil }
        pending.append(piece)
        guard bytesLeft == 0, flags & Self.cont == 0 else { return nil }
        defer { pending = Data() }
        return .message(pending)
    }
}

#if os(Linux) || CANDY_CURL_WS
import CCurl
#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// The helper's WebSocket on Linux: libcurl's own frame API (`CURLOPT_CONNECT_ONLY` 2, `curl_ws_recv`, `curl_ws_send`)
/// with `WebSocketAssembler`, instead of URLSessionWebSocketTask, which splits large messages there. TLS for wss:// is
/// curl's, as it already was through FoundationNetworking. One reader thread polls the socket; one lock guards the handle.
final class CurlRPCSocket: RPCSocket, @unchecked Sendable {
    private let handle: UnsafeMutableRawPointer
    private let fd: Int32
    private let lock = NSLock()
    private let messages: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var iterator: AsyncThrowingStream<Data, Error>.AsyncIterator
    private var stopped = false

    private static let initialized: Bool = { curl_global_init(Int(CURL_GLOBAL_DEFAULT)) == CURLE_OK }()

    /// Where the system keeps its CA certificates, for curl's TLS: `SSL_CERT_FILE`, then the usual Linux places.
    private static let caBundle: String? = {
        let candidates = [ProcessInfo.processInfo.environment["SSL_CERT_FILE"], "/etc/ssl/certs/ca-certificates.crt",
                          "/etc/pki/tls/certs/ca-bundle.crt", "/etc/ssl/ca-bundle.pem", "/etc/ssl/cert.pem"]
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0) }
    }()

    /// Connects and upgrades on a thread of its own, since curl blocks there.
    static func open(url: URL, openTimeout: Duration = .seconds(15)) async throws -> CurlRPCSocket {
        try await withCheckedThrowingContinuation { c in
            Thread.detachNewThread {
                do { c.resume(returning: try CurlRPCSocket(url: url, timeout: openTimeout)) } catch { c.resume(throwing: error) }
            }
        }
    }

    private init(url: URL, timeout: Duration) throws {
        guard Self.initialized, let h = curl_easy_init() else { throw RPCTransportError.closed("libcurl didn't start") }
        _ = ccurl_set_string(h, CURLOPT_URL, url.absoluteString)
        _ = ccurl_set_long(h, CURLOPT_CONNECT_ONLY, 2)
        _ = ccurl_set_long(h, CURLOPT_CONNECTTIMEOUT_MS, Int(timeout.components.seconds * 1000))
        _ = ccurl_set_long(h, CURLOPT_NOSIGNAL, 1)
        #if os(Linux)
        if let ca = Self.caBundle { _ = ccurl_set_string(h, CURLOPT_CAINFO, ca) }
        #endif
        let rc = curl_easy_perform(h)
        var status = 0
        _ = ccurl_get_long(h, CURLINFO_RESPONSE_CODE, &status)
        guard rc == CURLE_OK else {
            let why = String(cString: curl_easy_strerror(rc))
            curl_easy_cleanup(h)
            if status != 0 && status != 101 { throw RPCTransportError.upgradeRejected(status: status) }
            throw RPCTransportError.closed(why)
        }
        var sock: curl_socket_t = -1
        _ = ccurl_get_socket(h, &sock)
        handle = h
        fd = Int32(sock)
        (messages, continuation) = AsyncThrowingStream.makeStream(of: Data.self)
        iterator = messages.makeAsyncIterator()
        Thread.detachNewThread { [self] in read() }
    }

    func send(_ frame: Data) async throws {
        try frame.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            lock.lock()
            defer { lock.unlock() }
            var offset = 0
            while offset < raw.count {
                guard !stopped else { throw RPCTransportError.closed("socket closed") }
                var sent = 0
                let rc = curl_ws_send(handle, raw.baseAddress! + offset, raw.count - offset, &sent, 0, UInt32(CURLWS_TEXT))
                if rc == CURLE_AGAIN {
                    lock.unlock()
                    var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&p, 1, 1000)
                    lock.lock()
                    continue
                }
                guard rc == CURLE_OK else { throw RPCTransportError.closed(String(cString: curl_easy_strerror(rc))) }
                offset += sent
            }
        }
    }

    func receive() async throws -> Data {
        guard let next = try await iterator.next() else { throw RPCTransportError.closed("socket closed") }
        return next
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return }
        stopped = true
        var sent = 0
        _ = curl_ws_send(handle, nil, 0, &sent, 0, UInt32(CURLWS_CLOSE))
        continuation.finish(throwing: RPCTransportError.closed("closed by client"))
    }

    /// The reader thread: waits for the socket, drains every frame piece curl has, and hands on whole messages.
    private func read() {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var assembler = WebSocketAssembler()
        defer {
            lock.lock()
            stopped = true
            curl_easy_cleanup(handle)
            lock.unlock()
        }
        while true {
            lock.lock()
            let done = stopped
            lock.unlock()
            if done { return }
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&p, 1, 500)
            if ready < 0 && errno != EINTR { continuation.finish(throwing: RPCTransportError.closed("poll failed (errno \(errno))")); return }
            if ready <= 0 { continue }
            lock.lock()
            while !stopped {
                var received = 0
                var meta: UnsafePointer<curl_ws_frame>?
                let rc = buffer.withUnsafeMutableBytes { curl_ws_recv(handle, $0.baseAddress, $0.count, &received, &meta) }
                if rc == CURLE_AGAIN { break }
                guard rc == CURLE_OK, let frame = meta?.pointee else {
                    lock.unlock()
                    continuation.finish(throwing: RPCTransportError.closed(rc == CURLE_OK ? "no frame" : String(cString: curl_easy_strerror(rc))))
                    return
                }
                switch assembler.feed(Data(buffer[0..<received]), flags: frame.flags, bytesLeft: Int(frame.bytesleft)) {
                case .message(let data)?: continuation.yield(data)
                case .close?:
                    lock.unlock()
                    continuation.finish(throwing: RPCTransportError.closed("the server closed the socket"))
                    return
                case nil: break
                }
            }
            lock.unlock()
        }
    }
}
#endif

/// The socket the helper opens: libcurl's frames on Linux (see `CurlRPCSocket`), URLSession elsewhere.
func openHelperSocket(_ url: URL) async throws -> any RPCSocket {
    #if os(Linux) || CANDY_CURL_WS
    try await CurlRPCSocket.open(url: url)
    #else
    try await URLSessionRPCSocket.open(url: url)
    #endif
}
