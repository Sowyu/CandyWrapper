// Composes "T3 (Chromium) | CandyWrapper" pairs into one labeled PNG.
// Usage: swift scripts/side-by-side.swift <out.png> <title> <ref1.png> <ours1.png> [<ref2.png> <ours2.png> ...]
import AppKit

let a = CommandLine.arguments
guard a.count >= 5, (a.count - 3) % 2 == 0 else { print("usage: side-by-side.swift out.png title ref ours [ref ours ...]"); exit(2) }
let out = a[1], title = a[2]
let pairs = stride(from: 3, to: a.count, by: 2).map { (NSImage(contentsOfFile: a[$0])!, NSImage(contentsOfFile: a[$0 + 1])!) }
func px(_ i: NSImage) -> CGSize { let r = i.representations[0]; return CGSize(width: r.pixelsWide, height: r.pixelsHigh) }
let gap: CGFloat = 24, header: CGFloat = 44, label: CGFloat = 30
let colW = pairs.map { max(px($0.0).width, px($0.1).width) }.max()!
let rowHs = pairs.map { max(px($0.0).height, px($0.1).height) }
let W = colW * 2 + gap * 3, H = header + rowHs.reduce(0) { $0 + $1 + label + gap } + gap
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H), bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSColor(white: 0.94, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: W, height: H).fill()
let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 22, weight: .semibold), .foregroundColor: NSColor.black]
let small: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.darkGray]
(title as NSString).draw(at: NSPoint(x: gap, y: H - header + 8), withAttributes: attrs)
var y = H - header
for (i, (ref, ours)) in pairs.enumerated() {
    y -= label
    ("T3 (Chromium)" as NSString).draw(at: NSPoint(x: gap, y: y + 6), withAttributes: small)
    ("CandyWrapper" as NSString).draw(at: NSPoint(x: gap * 2 + colW, y: y + 6), withAttributes: small)
    y -= rowHs[i]
    ref.draw(in: NSRect(x: gap, y: y, width: px(ref).width, height: px(ref).height))
    ours.draw(in: NSRect(x: gap * 2 + colW, y: y, width: px(ours).width, height: px(ours).height))
    y -= gap
}
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print(out)
