// Packs PNGs into a grid. Usage: grid <out.png> <columns> <cell width px> <in...>
import AppKit
let a = CommandLine.arguments
let out = a[1], cols = Int(a[2])!, cellW = CGFloat(Double(a[3])!)
let images = a.dropFirst(4).compactMap { NSImage(contentsOfFile: $0) }
guard let first = images.first else { exit(1) }
let cellH = (cellW * first.size.height / first.size.width).rounded()
let rows = (images.count + cols - 1) / cols
let size = NSSize(width: cellW * CGFloat(cols) + CGFloat(cols - 1) * 8, height: cellH * CGFloat(rows) + CGFloat(rows - 1) * 8)
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSColor.red.setFill(); NSRect(origin: .zero, size: size).fill()
for (i, img) in images.enumerated() {
    let c = i % cols, r = i / cols
    img.draw(in: NSRect(x: CGFloat(c) * (cellW + 8), y: size.height - CGFloat(r + 1) * cellH - CGFloat(r) * 8, width: cellW, height: cellH))
}
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
