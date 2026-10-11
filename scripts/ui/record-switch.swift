// Records one app's window with ScreenCaptureKit at up to 60 frames a second while it clicks a list
// of points, then lists every delivered frame (time, changed fraction against the previous frame and
// the changed box) and writes each frame as a PNG at 1 pixel per point. Finds thread-switch flicker:
// a frame that matches neither the state before a click nor the state it settles on.
// The window must stay frontmost; clicks are skipped otherwise.
// Build: swiftc -O -o /tmp/cw-ui/record-switch scripts/ui/record-switch.swift
// Usage: record-switch <pid> <outdir> <seconds between clicks> <x,y> [<x,y> ...]   (screen points, top-left origin)
import AppKit
import CoreImage
import CoreMedia
import ScreenCaptureKit

_ = NSApplication.shared  // CGS needs an app connection before ScreenCaptureKit starts
let args = CommandLine.arguments
guard args.count >= 5, let pid = Int32(args[1]), let gap = Double(args[3]) else {
    print("usage: record-switch <pid> <outdir> <gap seconds> <x,y> ..."); exit(2)
}
let out = URL(fileURLWithPath: args[2])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let points = args[4...].map { s -> CGPoint in
    let p = s.split(separator: ",").compactMap { Double($0) }
    return CGPoint(x: p[0], y: p[1])
}

struct Frame { var t: Double; var w: Int; var h: Int; var px: [UInt8] }

final class Sink: NSObject, SCStreamOutput, @unchecked Sendable {
    var frames: [Frame] = []
    let lock = NSLock()
    let start = CACurrentMediaTime()
    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let info = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let buffer = CMSampleBufferGetImageBuffer(sb) else { return }
        let t = CACurrentMediaTime() - start
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer), row = CVPixelBufferGetBytesPerRow(buffer)
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        px.withUnsafeMutableBytes { dst in
            for y in 0..<h { memcpy(dst.baseAddress! + y * w * 4, base + y * row, w * 4) }
        }
        CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        lock.withLock { frames.append(Frame(t: t, w: w, h: h, px: px)) }
    }
}

func click(_ p: CGPoint) {
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { print("pid \(pid) not frontmost, click skipped"); return }
    for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
        let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)
        if type != .mouseMoved { e?.setIntegerValueField(.mouseEventClickState, value: 1) }
        e?.post(tap: .cghidEventTap)
        usleep(20_000)
    }
}

/// Changed pixel count and box between two frames (any channel off by more than 6 levels).
func diff(_ a: Frame, _ b: Frame) -> (Int, Int, Int, Int, Int) {
    guard a.w == b.w, a.h == b.h else { return (b.w * b.h, 0, 0, b.w - 1, b.h - 1) }
    var n = 0, x0 = b.w, y0 = b.h, x1 = -1, y1 = -1
    a.px.withUnsafeBufferPointer { p in
        b.px.withUnsafeBufferPointer { q in
            for y in 0..<b.h {
                for x in 0..<b.w {
                    let o = (y * b.w + x) * 4
                    if abs(Int(p[o]) - Int(q[o])) > 6 || abs(Int(p[o + 1]) - Int(q[o + 1])) > 6 || abs(Int(p[o + 2]) - Int(q[o + 2])) > 6 {
                        n += 1; x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
                    }
                }
            }
        }
    }
    return (n, x0, y0, x1, y1)
}

let sink = Sink()
Task {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    guard let window = content.windows.filter({ $0.owningApplication?.processID == pid && $0.windowLayer == 0 })
        .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else { print("no window for pid \(pid)"); exit(1) }
    print("window", window.frame)
    let config = SCStreamConfiguration()
    config.width = Int(window.frame.width)
    config.height = Int(window.frame.height)
    config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
    config.pixelFormat = kCVPixelFormatType_32BGRA
    config.showsCursor = false
    config.queueDepth = 8
    let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: config, delegate: nil)
    try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: DispatchQueue(label: "capture"))
    try await stream.startCapture()
    try await Task.sleep(for: .milliseconds(600))
    var clicks: [Double] = []
    for p in points {
        clicks.append(CACurrentMediaTime() - sink.start)
        click(p)
        try await Task.sleep(for: .seconds(gap))
    }
    try await stream.stopCapture()
    let frames = sink.lock.withLock { sink.frames }
    var report = ""
    let context = CIContext()
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    for (i, f) in frames.enumerated() {
        let (n, x0, y0, x1, y1) = i == 0 ? (0, 0, 0, 0, 0) : diff(frames[i - 1], f)
        report += String(format: "%04d t=%.3f changed=%.4f box=%d,%d-%d,%d\n", i, f.t, Double(n) / Double(f.w * f.h), x0, y0, x1, y1)
        let image = CIImage(bitmapData: Data(f.px), bytesPerRow: f.w * 4, size: CGSize(width: f.w, height: f.h), format: .BGRA8, colorSpace: space)
        try? context.writePNGRepresentation(of: image, to: out.appendingPathComponent(String(format: "f%04d.png", i)), format: .RGBA8, colorSpace: space)
    }
    report += "clicks " + clicks.map { String(format: "%.3f", $0) }.joined(separator: " ") + "\n"
    try report.write(to: out.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
    print(report)
    exit(0)
}
RunLoop.main.run()
