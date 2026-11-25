// Frame timing on screen for the README side by side (docs/benchmarks.md). Watches a region of the main display
// with ScreenCaptureKit, keeps the display time of every frame whose pixels changed, and posts HID input meanwhile.
// The app under test must be frontmost and cover the region. Needs Screen Recording and Accessibility.
//
// Usage:
//   frames scroll <x> <y> <w> <h> <events> <px> [interval-ms]  pixel scroll events (down) at the region's center,
//                                                             default every 8 ms; prints frame gaps while it moves
//   frames key <x> <y> <w> <h> <count> [interval-ms]          types `a` count times, default 600 ms apart, then
//                                                             deletes them, each press 0 to 17 ms late; prints keypress to first frame whose
//                                                             change is wider than a caret (4 px)
// Coordinates are global points, top-left origin. A slow frame is a gap over 20 ms (60 Hz).
// Build: swiftc -O scripts/perf/frames.swift -o /tmp/cw-perf/bin/frames
import AppKit
import CoreMedia
import ScreenCaptureKit

struct Frame { let ns: UInt64; let changedWidth: Int }

var timebase = mach_timebase_info_data_t()
mach_timebase_info(&timebase)
func ns(_ mach: UInt64) -> UInt64 { mach * UInt64(timebase.numer) / UInt64(timebase.denom) }
func now() -> UInt64 { ns(mach_absolute_time()) }

final class Watcher: NSObject, SCStreamOutput {
    let lock = NSLock()
    var frames: [Frame] = []
    var previous: [UInt8]?

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let display = info[.displayTime] as? UInt64,
              let pixels = CMSampleBufferGetImageBuffer(buffer) else { return }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
        let stride = CVPixelBufferGetBytesPerRow(pixels)
        let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
        var current = [UInt8](repeating: 0, count: width * height * 4)
        for row in 0..<height { memcpy(&current[row * width * 4], base + row * stride, width * 4) }
        var changedWidth = 0
        if let previous, previous.count == current.count {
            var minX = Int.max, maxX = -1
            current.withUnsafeBufferPointer { c in
                previous.withUnsafeBufferPointer { p in
                    for row in 0..<height {
                        let off = row * width * 4
                        if memcmp(c.baseAddress! + off, p.baseAddress! + off, width * 4) == 0 { continue }
                        for x in 0..<width where memcmp(c.baseAddress! + off + x * 4, p.baseAddress! + off + x * 4, 4) != 0 {
                            minX = min(minX, x); maxX = max(maxX, x)
                        }
                    }
                }
            }
            if maxX >= 0 { changedWidth = maxX - minX + 1 }
        }
        previous = current
        lock.lock(); frames.append(Frame(ns: ns(display), changedWidth: changedWidth)); lock.unlock()
    }

    var snapshot: [Frame] { lock.lock(); defer { lock.unlock() }; return frames }
}

func fail(_ message: String) -> Never { FileHandle.standardError.write(Data((message + "\n").utf8)); exit(2) }

let args = CommandLine.arguments
guard args.count >= 7, let x = Double(args[2]), let y = Double(args[3]), let w = Double(args[4]), let h = Double(args[5]),
      let count = Int(args[6]) else {
    fail("usage: frames scroll <x> <y> <w> <h> <events> <px> [interval-ms] | frames key <x> <y> <w> <h> <count> [interval-ms]")
}
let mode = args[1]
let center = CGPoint(x: x + w / 2, y: y + h / 2)

let watcher = Watcher()
let started = DispatchSemaphore(value: 0)
var stream: SCStream?
Task {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) else { fail("no main display") }
        let scale = NSScreen.main?.backingScaleFactor ?? 1
        let config = SCStreamConfiguration()
        config.sourceRect = CGRect(x: x, y: y, width: w, height: h)
        config.width = Int(w * scale); config.height = Int(h * scale)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 240)
        config.queueDepth = 8
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        let s = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: nil)
        try s.addStreamOutput(watcher, type: .screen, sampleHandlerQueue: DispatchQueue(label: "frames"))
        try await s.startCapture()
        stream = s
        started.signal()
    } catch { fail("capture failed: \(error)") }
}
started.wait()
usleep(500_000)

func sleepUntil(_ target: UInt64) { let t = now(); if target > t { usleep(UInt32((target - t) / 1000)) } }
func percentile(_ v: [Double], _ p: Double) -> Double { let s = v.sorted(); return s[min(s.count - 1, Int(Double(s.count - 1) * p))] }
func fmt(_ v: Double) -> String { String(format: "%.1f", v) }

if mode == "scroll" {
    guard args.count >= 8, let px = Int32(args[7]) else { fail("scroll needs <px>") }
    let interval = UInt64((args.count >= 9 ? Double(args[8]) ?? 8 : 8) * 1_000_000)
    let first = now()
    for i in 0..<count {
        sleepUntil(first + UInt64(i) * interval)
        let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -px, wheel2: 0, wheel3: 0)!
        e.location = center
        e.post(tap: .cghidEventTap)
    }
    let last = now()
    usleep(400_000)
    let moving = watcher.snapshot.filter { $0.changedWidth > 0 && $0.ns >= first && $0.ns <= last + 100_000_000 }
    let gaps = zip(moving.dropFirst(), moving).map { Double($0.ns - $1.ns) / 1e6 }
    guard !gaps.isEmpty else { fail("no changed frames; is the app frontmost over the region?") }
    let slow = gaps.filter { $0 > 20 }
    print("{\"mode\":\"scroll\",\"events\":\(count),\"px\":\(px),\"input_ms\":\(fmt(Double(last - first) / 1e6)),\"frames\":\(moving.count),"
        + "\"gaps\":\(gaps.count),\"over20\":\(slow.count),\"max_ms\":\(fmt(gaps.max()!)),\"median_ms\":\(fmt(percentile(gaps, 0.5))),"
        + "\"slow_ms\":[\(slow.map(fmt).joined(separator: ","))]}")
} else if mode == "key" {
    let interval = UInt64((args.count >= 8 ? Double(args[7]) ?? 600 : 600) * 1_000_000)
    func press(_ code: CGKeyCode) {
        for down in [true, false] { CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!.post(tap: .cghidEventTap) }
    }
    // 600 ms is a whole number of 60 Hz frames, so fixed spacing lands every press on the same frame phase.
    // A random 0 to 17 ms offset spreads the presses over the frame.
    var posts: [UInt64] = []
    var next = now()
    for _ in 0..<count {
        sleepUntil(next)
        next += interval + UInt64.random(in: 0..<17_000_000)
        posts.append(now())
        press(0)  // a
    }
    usleep(UInt32(interval / 1000))
    let frames = watcher.snapshot
    var latencies: [Double] = []
    for (i, t) in posts.enumerated() {
        let end = i + 1 < posts.count ? posts[i + 1] : t + interval
        if let f = frames.first(where: { $0.ns > t && $0.ns < end && $0.changedWidth > 4 }) { latencies.append(Double(f.ns - t) / 1e6) }
    }
    for _ in 0..<count { press(51); usleep(30_000) }  // delete
    guard !latencies.isEmpty else { fail("no glyph frames; is the composer focused and frontmost?") }
    print("{\"mode\":\"key\",\"presses\":\(count),\"seen\":\(latencies.count),\"median_ms\":\(fmt(percentile(latencies, 0.5))),"
        + "\"min_ms\":\(fmt(latencies.min()!)),\"max_ms\":\(fmt(latencies.max()!)),\"all_ms\":[\(latencies.map(fmt).joined(separator: ","))]}")
} else {
    fail("unknown mode \(mode)")
}
let done = DispatchSemaphore(value: 0)
Task { try? await stream?.stopCapture(); done.signal() }
done.wait()
