import Foundation
import ImageIO
import CoreImage
@preconcurrency import VideoToolbox
import T3Protocol

/// Native transport for stream.ts:9-17. No sockets, decoder or HTTP body survive stop().
@MainActor
public final class DevicePanelStreamClient {
    /// Android frames, decoded from H.264.
    public var onFrame: ((CGImage) -> Void)?
    /// iOS frames: each JPEG decoded off the main thread into an IOSurface-backed buffer, as the browser
    /// preview does since WP8.5 (docs/perf/README.md, "Heavy surfaces"), so Core Animation shows it as is.
    public var onSurface: ((CVPixelBuffer) -> Void)?
    public var onOrientation: ((String) -> Void)?
    public var onError: ((String) -> Void)?
    private var socket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var tasks: [Task<Void, Never>] = []
    private let jpeg = FrameDecoder(decode: { [decoder = JPEGSurfaceDecoder()] in decoder.decode($0) })
    private let video = DevicePanelVideoDecoder()
    private let platform: String
    private var stopped = false
    public init(platform: String) { self.platform = platform }

    public func start(videoURL: URL, inputURL: URL) {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = 60
        let session = URLSession(configuration: config)
        self.session = session
        jpeg.deliver = { [weak self] buffer in self?.onSurface?(buffer) }
        let socket = session.webSocketTask(with: inputURL)
        socket.maximumMessageSize = 16 * 1024 * 1024
        self.socket = socket
        if platform == "android" {
            socket.resume()
            socket.send(.string("{\"type\":\"reset-video\",\"ack\":false}")) { _ in }
        }
        tasks.append(Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    guard let self, !self.stopped else { return }
                    if self.platform == "ios", case .data(let data) = message, data.first == 0x82,
                       let json = try? JSONDecoder().decode(JSONValue.self, from: data.dropFirst()), let orientation = json["orientation"]?.stringValue {
                        self.onOrientation?(orientation)
                    }
                    if self.platform == "android", case .data(let data) = message,
                       let frame = await self.video.decode(data), !self.stopped { self.onFrame?(frame) }
                }
            } catch { if let self, !self.stopped { self.onError?("Device input disconnected. Refresh devices to reconnect.") } }
        })
        if platform == "ios" {
            let decoder = jpeg
            tasks.append(Task.detached(priority: .userInitiated) { [weak self] in
                do {
                    let (bytes, response) = try await session.bytes(from: videoURL)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                    await MainActor.run {
                        guard let self, !self.stopped else { return }
                        socket.resume()
                        self.send(DevicePanelWire.tagged(0x0d, .object(["enabled": .bool(false)])))
                    }
                    var parser = DevicePanelJPEGParser()
                    var chunk = Data()
                    chunk.reserveCapacity(16384)
                    var previous: UInt8 = 0
                    // ponytail: AsyncBytes yields one byte per await; read chunks through a URLSessionDataDelegate if streaming CPU shows in M8
                    for try await byte in bytes {
                        if Task.isCancelled { return }
                        chunk.append(byte)
                        // JPEG end markers (FF D9) let low-volume streams deliver their first frame immediately.
                        // Compared byte by byte: a slice and a Data per byte cost millions of allocations a second.
                        let frameEnd = previous == 0xff && byte == 0xd9
                        previous = byte
                        if chunk.count >= 16384 || frameEnd {
                            for frame in parser.push(chunk) { decoder.paint(frame) }
                            chunk.removeAll(keepingCapacity: true)
                        }
                    }
                } catch {
                    await MainActor.run { if let self, !self.stopped { self.onError?("Device stream unavailable. Refresh devices to reconnect.") } }
                }
            })
        }
    }
    public func send(_ data: Data) {
        guard !stopped else { return }
        if platform == "ios" { socket?.send(.data(data)) { _ in } }
        else if let text = String(data: data, encoding: .utf8) { socket?.send(.string(text)) { _ in } }
    }
    public func press(_ button: String) {
        if platform == "ios" {
            let name = button == "power" ? "lock" : button == "appSwitcher" ? "app_switcher" : button
            send(DevicePanelWire.tagged(4, .object(["button": .string(name)])))
        } else { send((try? JSONEncoder().encode(JSONValue.object(["type": .string(button)]))) ?? Data()) }
    }
    public func key(code: UInt16, text: String?, down: Bool) {
        // macOS virtual key codes to USB HID usages, stream.ts's hidUsageForCode.
        let hid: [UInt16: Int] = [0:4,1:22,2:7,3:9,4:11,5:10,6:29,7:27,8:6,9:25,11:5,12:20,13:26,14:8,15:21,16:28,17:23,31:18,32:24,34:12,35:19,37:15,38:13,40:14,45:17,46:16,36:40,48:43,49:44,51:42,53:41,123:80,124:79,125:81,126:82,18:30,19:31,20:32,21:33,23:34,22:35,26:36,28:37,25:38,29:39,27:45,24:46,33:47,30:48,42:49,41:51,39:52,50:53,43:54,47:55,44:56,117:76,59:224,56:225,58:226,55:227,62:228,60:229,61:230,54:231]
        if platform == "ios", let usage = hid[code] {
            send(DevicePanelWire.tagged(6, .object(["type": .string(down ? "down" : "up"), "usage": .number(Double(usage))])))
        } else if platform == "android", down {
            let keys: [UInt16: Int] = [36:66,48:61,51:67,123:21,124:22,125:20,126:19,117:112,115:122,119:123,116:92,121:93]
            let json: JSONValue
            if code == 53 { json = .object(["type": .string("back")]) }
            else if let key = keys[code] { json = .object(["type": .string("key"), "keycode": .number(Double(key))]) }
            else if let text, text.count == 1 { json = .object(["type": .string("text"), "text": .string(text)]) }
            else { return }
            send((try? JSONEncoder().encode(json)) ?? Data())
        }
    }
    public func stop() {
        stopped = true
        tasks.forEach { $0.cancel() }; tasks.removeAll()
        socket?.cancel(with: .normalClosure, reason: nil); socket = nil
        session?.invalidateAndCancel(); session = nil
        jpeg.stop()
        Task { await video.stop() }
        onFrame = nil; onError = nil
    }
}

/// Android SEMU / Annex-B frames (stream.ts:162-217), decoded serially off the main actor.
/// The socket awaits each decode, bounding the native decoder queue to one access unit.
private actor DevicePanelVideoDecoder {
    private var format: CMVideoFormatDescription?
    private var decoder: VTDecompressionSession?
    private var sps: Data?
    private var pps: Data?
    private var formatDirty = false
    private var stopped = false
    private let context = CIContext(options: [.cacheIntermediates: false])
    func stop() { stopped = true; if let decoder { VTDecompressionSessionInvalidate(decoder) }; decoder = nil; format = nil }
    func decode(_ packet: Data) -> CGImage? {
        guard !stopped else { return nil }
        let bytes = [UInt8](packet)
        let offset = bytes.count > 16 && Array(bytes.prefix(5)) == [0x53, 0x45, 0x4d, 0x55, 1] ? 16 : 0
        var starts: [(Int, Int)] = []
        var i = offset
        while i + 3 < bytes.count {
            if bytes[i] == 0 && bytes[i+1] == 0 {
                if bytes[i+2] == 1 { starts.append((i, 3)); i += 3; continue }
                if bytes[i+2] == 0 && bytes[i+3] == 1 { starts.append((i, 4)); i += 4; continue }
            }
            i += 1
        }
        var payload = Data()
        var changed = false
        var key = false
        for (index, start) in starts.enumerated() {
            let end = index + 1 < starts.count ? starts[index+1].0 : bytes.count
            guard start.0 + start.1 < end else { continue }
            let nal = Data(bytes[(start.0+start.1)..<end])
            let type = nal.first! & 31
            if type == 7 { changed = changed || sps != nal; sps = nal }
            if type == 8 { changed = changed || pps != nal; pps = nal }
            if type == 5 { key = true }
            var length = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &length) { payload.append(contentsOf: $0) }
            payload.append(nal)
        }
        formatDirty = formatDirty || changed
        if formatDirty || decoder == nil {
            guard let sps, let pps, key else { return nil }
            if let decoder { VTDecompressionSessionInvalidate(decoder) }
            decoder = nil
            let status = sps.withUnsafeBytes { s in pps.withUnsafeBytes { p in
                let pointers = [s.baseAddress!.assumingMemoryBound(to: UInt8.self), p.baseAddress!.assumingMemoryBound(to: UInt8.self)]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: 2,
                    parameterSetPointers: pointers, parameterSetSizes: [sps.count, pps.count], nalUnitHeaderLength: 4, formatDescriptionOut: &format)
            }}
            guard status == noErr, let format else { return nil }
            guard VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil,
                imageBufferAttributes: [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as CFDictionary,
                outputCallback: nil, decompressionSessionOut: &decoder) == noErr else { return nil }
        }
        formatDirty = false
        guard let decoder, let format, !payload.isEmpty else { return nil }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: payload.count,
            blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: payload.count, flags: 0, blockBufferOut: &block) == noErr,
            let block else { return nil }
        _ = payload.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: payload.count) }
        var sample: CMSampleBuffer?
        var size = payload.count
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
            let sample else { return nil }
        let result = DevicePanelDecodedFrame()
        let context = self.context
        _ = VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, buffer, _, _ in
            if status == noErr, let buffer {
                let ci = CIImage(cvPixelBuffer: buffer)
                result.image = context.createCGImage(ci, from: ci.extent)
            }
        }
        VTDecompressionSessionWaitForAsynchronousFrames(decoder)
        return result.image
    }
}
private final class DevicePanelDecodedFrame: @unchecked Sendable { var image: CGImage? }
