import Foundation
import ImageIO
import CoreMedia
import CoreVideo
import IOSurface
@preconcurrency import VideoToolbox
import T3Protocol

/// One viewer of a server browser tab (`createPreviewStreamClient` plus `createPreviewFramePainter`,
/// packages/client-runtime/src/preview/serverBrowserStream.ts). It acks every JPEG frame at once,
/// decodes off the main thread one frame at a time and keeps only the newest waiting one, so a slow
/// viewer drops frames instead of queueing them. JSON messages arrive decoded on the main actor.
/// It reconnects with T3's backoff and stops for good on 4404, 4503 and a refused upgrade.
@MainActor
public final class PreviewStreamClient {
    public struct Events {
        public var onFrame: @MainActor (CVPixelBuffer) -> Void = { _ in }
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
    private let decoder = FrameDecoder(decode: { [jpeg = JPEGSurfaceDecoder()] in jpeg.decode($0) })

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
/// that arrives meanwhile replaces the one waiting. Decoded frames reach the main thread one hop at a
/// time: a frame decoded before the main thread took the last one replaces it, so a busy main thread
/// skips frames it could not show instead of queueing them.
final class FrameDecoder<Frame>: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.candywrapper.preview-frames", qos: .userInitiated)
    private let lock = NSLock()
    private let decodeFrame: @Sendable (Data) -> Frame?
    private var decoding = false
    private var waiting: Data?
    /// The newest decoded frame the main thread has not taken yet.
    private var ready: Frame?
    private var stopped = false
    @MainActor var deliver: (@MainActor (Frame) -> Void)?

    init(decode: @escaping @Sendable (Data) -> Frame?) { decodeFrame = decode }

    func paint(_ jpeg: Data) {
        let start: Bool = lock.withLock {
            if stopped { return false }
            if decoding { waiting = jpeg; return false }
            decoding = true
            return true
        }
        if start { queue.async { self.decode(jpeg) } }
    }

    func stop() { lock.withLock { stopped = true; waiting = nil; ready = nil } }

    private func decode(_ jpeg: Data) {
        // A frame that fails to decode is skipped; the next one repaints.
        if let frame = decodeFrame(jpeg) {
            let hop: Bool = lock.withLock {
                if stopped { return false }
                defer { ready = frame }
                return ready == nil
            }
            if hop {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let frame = self.lock.withLock({ () -> Frame? in defer { self.ready = nil }; return self.ready }) else { return }
                        self.deliver?(frame)
                    }
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
}

enum JPEGFrame {
    /// An ImageIO image. Core Animation decodes it again on the main thread when a layer shows it
    /// (`CA::Render::copy_image` asks ImageIO for an IOSurface). Only the device panel uses it.
    static func image(_ jpeg: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    /// The frame's size from its header, without decoding it.
    static func size(_ jpeg: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        return (width, height)
    }

    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Tags the buffer sRGB, the JPEG's color space, so the window server matches its colors.
    /// VideoToolbox guesses "Composite NTSC" for a JPEG without a profile.
    static func tag(_ buffer: CVPixelBuffer) {
        CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, sRGB, .shouldPropagate)
        if let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue(), let list = sRGB.copyPropertyList() {
            IOSurfaceSetValue(surface, kIOSurfaceColorSpace, list)
        }
    }

    /// The CPU path, for a frame the hardware session refuses: ImageIO draws the JPEG into a new
    /// IOSurface-backed BGRA buffer.
    static func drawn(_ jpeg: Data) -> CVPixelBuffer? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        var made: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, image.width, image.height, kCVPixelFormatType_32BGRA,
                                  [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &made) == kCVReturnSuccess,
              let buffer = made else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: sRGB,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.setBlendMode(.copy)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        tag(buffer)
        return buffer
    }
}

/// Decodes a stream's JPEG frames on the media engine with one VideoToolbox session, into
/// IOSurface-backed BGRA buffers that a layer shows as they are. An ImageIO image decoded again on
/// the main thread when Core Animation committed it, which was nearly all of the main thread's work
/// on an animated page; decoding with ImageIO into our own surface moved that work to this queue
/// but still cost about 1.7 ms of CPU per 800x1090 frame, the session about 0.1 ms. The session
/// follows the frame size; a frame it refuses takes the CPU path. Used only on the decoder's queue.
final class JPEGSurfaceDecoder: @unchecked Sendable {
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var size = (width: 0, height: 0)

    deinit { if let session { VTDecompressionSessionInvalidate(session) } }

    func decode(_ jpeg: Data) -> CVPixelBuffer? {
        // A frame past T3's largest viewport at 2x (3840 by 2160 points) is refused before any buffer exists.
        guard let frameSize = JPEGFrame.size(jpeg), frameSize.width * frameSize.height <= 7680 * 4320 else { return nil }
        if session == nil || frameSize != size { open(frameSize) }
        if let buffer = hardware(jpeg) { JPEGFrame.tag(buffer); return buffer }
        return JPEGFrame.drawn(jpeg)
    }

    private func open(_ frameSize: (width: Int, height: Int)) {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        format = nil
        size = frameSize
        guard CMVideoFormatDescriptionCreate(allocator: nil, codecType: kCMVideoCodecType_JPEG, width: Int32(frameSize.width),
                                             height: Int32(frameSize.height), extensions: nil, formatDescriptionOut: &format) == noErr,
              let format else { return }
        VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil,
                                     imageBufferAttributes: [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                                                             kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                                     outputCallback: nil, decompressionSessionOut: &session)
    }

    private final class Output: @unchecked Sendable { var buffer: CVPixelBuffer? }

    private func hardware(_ jpeg: Data) -> CVPixelBuffer? {
        guard let session, let format else { return nil }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: jpeg.count, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: jpeg.count, flags: 0,
                                                 blockBufferOut: &block) == noErr, let block,
              jpeg.withUnsafeBytes({ CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0,
                                                                   dataLength: jpeg.count) }) == noErr else { return nil }
        var sample: CMSampleBuffer?
        var bytes = jpeg.count
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 0,
                                        sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &bytes,
                                        sampleBufferOut: &sample) == noErr, let sample else { return nil }
        let output = Output()
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, buffer, _, _ in
            if status == noErr { output.buffer = buffer }
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        return status == noErr ? output.buffer : nil
    }
}
