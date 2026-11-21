import VideoToolbox

// Records one app's window, and popovers or menus that open over it, as PNG frames while other windows cover
// it. ScreenCaptureKit sends a frame only when the picture changes, so an idle window gives few frames.
// Usage: record [pid] <seconds> <outdir>, pid defaults to CW_UI_PID. CW_UI_FPS caps the frame rate (default 30).
// Writes f0000.png... and frames.txt with each frame's time in seconds since the start.
let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2, let seconds = Double(args[args.count - 2]),
      let pid = pidArgument(args.count > 2 ? args[0] : nil) else { print("usage: record [pid] <seconds> <outdir>"); exit(2) }
let out = URL(fileURLWithPath: args[args.count - 1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let fps = Int32(ProcessInfo.processInfo.environment["CW_UI_FPS"] ?? "") ?? 30

final class Sink: NSObject, SCStreamOutput, @unchecked Sendable {
    let start = CACurrentMediaTime()
    let writer = DispatchQueue(label: "png")
    let lock = NSLock()
    var count = 0, pending = 0, dropped = 0
    var times = ""
    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let info = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let buffer = CMSampleBufferGetImageBuffer(sb) else { return }
        let t = CACurrentMediaTime() - start
        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image)
        guard let image else { return }
        let index: Int? = lock.withLock {
            // PNG encoding is slower than 30 big frames a second; drop rather than hold seconds of frames.
            guard pending < 8 else { dropped += 1; return nil }
            pending += 1; count += 1
            times += String(format: "f%04d.png %.3f\n", count - 1, t)
            return count - 1
        }
        guard let index else { return }
        writer.async {
            _ = writePNG(image, to: out.appendingPathComponent(String(format: "f%04d.png", index)).path)
            self.lock.withLock { self.pending -= 1 }
        }
    }
}

let sink = Sink()
runMain(watchdogSeconds: Int(seconds) + 20) {
    let t = try await captureTarget(pid: pid)
    t.config.minimumFrameInterval = CMTime(value: 1, timescale: fps)
    t.config.queueDepth = 6
    let stream = SCStream(filter: t.filter, configuration: t.config, delegate: nil)
    try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: DispatchQueue(label: "capture"))
    try await stream.startCapture()
    try await Task.sleep(for: .seconds(seconds))
    try await stream.stopCapture()
    sink.writer.sync {}
    let (count, dropped, times) = sink.lock.withLock { (sink.count, sink.dropped, sink.times) }
    try times.write(to: out.appendingPathComponent("frames.txt"), atomically: true, encoding: .utf8)
    print("recorded \(count) frames into \(out.path), \(dropped) dropped, origin \(Int(t.origin.x)) \(Int(t.origin.y)) scale \(Int(t.scale)) \(t.note)")
}
