import AppKit

// Takes a picture of one app's window and the child windows over it (sheets, menus, tooltips), even while other
// windows cover it or another app is frontmost. Usage: shot [pid] <out.png>, pid defaults to CW_UI_PID.
// It runs `screencapture -l` once per window and stacks the pictures in window order: the window server keeps
// every window's contents, so this needs no screen lock. ScreenCaptureKit's daemon (replayd) hung for minutes
// on 2026-11-20 while screencapture -l kept working, so shot does not use it.
// Prints the picture's top-left corner in global points and its scale, so a pixel (px, py) in the picture is
// the global point (x + px / scale, y + py / scale) that click, scroll and type take.
let args = Array(CommandLine.arguments.dropFirst())
guard let out = args.last, out.hasSuffix(".png"), let pid = pidArgument(args.count > 1 ? args[0] : nil) else {
    print("usage: shot [pid] <out.png>"); exit(2)
}
guard let main = mainWindow(pid) else { FileHandle.standardError.write(Data("no window for pid \(pid)\n".utf8)); exit(1) }
let windows = [main] + childWindows(pid, of: main).reversed()  // back to front

func capture(_ w: AppWindow) -> CGImage? {
    let file = NSTemporaryDirectory() + "shot-\(getpid())-\(w.id).png"
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-x", "-o", "-l\(w.id)", file]
    guard (try? p.run()) != nil else { return nil }
    p.waitUntilExit()
    // Read the bytes before deleting the file: CGImageSource decodes lazily, from the file, at draw time.
    defer { try? FileManager.default.removeItem(atPath: file) }
    guard let data = FileManager.default.contents(atPath: file), let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
}

guard let base = capture(main) else { FileHandle.standardError.write(Data("screencapture -l\(main.id) failed\n".utf8)); exit(1) }
let scale = CGFloat(base.width) / main.bounds.width
let region = windows.reduce(main.bounds) { $0.union($1.bounds) }
let ctx = CGContext(data: nil, width: Int((region.width * scale).rounded()), height: Int((region.height * scale).rounded()),
                    bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
var drawn = 0
for w in windows {
    guard let image = w.id == main.id ? base : capture(w) else { continue }
    // CoreGraphics counts y from the bottom.
    let rect = CGRect(x: (w.bounds.minX - region.minX) * scale, y: (region.maxY - w.bounds.maxY) * scale,
                      width: w.bounds.width * scale, height: w.bounds.height * scale)
    ctx.draw(image, in: rect)
    drawn += 1
}
guard let image = ctx.makeImage(), writePNG(image, to: out) else { FileHandle.standardError.write(Data("could not write \(out)\n".utf8)); exit(1) }
let place = main.onscreen ? "" : " (window not on the current Space)"
print("shot \(out) origin \(Int(region.minX)) \(Int(region.minY)) scale \(Int(scale)) size \(image.width)x\(image.height) windows \(drawn)\(place)")
