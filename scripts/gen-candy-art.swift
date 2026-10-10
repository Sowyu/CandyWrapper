// Bakes the sidebar header art from "Candy Town" by Aya_Lu on Pixabay
// (https://pixabay.com/illustrations/candy-town-city-buildings-8579300/, Pixabay Content License,
// largest public size 1280x905). Keeps the teddy-and-milk corner the 80pt band can show at any
// sidebar width, as 8-bit luma. StageBackdropView maps the file and paints each appearance's duotone.
// Usage: swift scripts/gen-candy-art.swift <candy-town-8579300_1280.jpg> <out.gray>
import CoreGraphics
import Foundation
import ImageIO

let args = CommandLine.arguments
guard args.count == 3, let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil), image.width == 1280, image.height == 905 else {
    FileHandle.standardError.write(Data("usage: gen-candy-art.swift <candy-town-8579300_1280.jpg (1280x905)> <out.gray>\n".utf8))
    exit(1)
}
// Source pixels, top-left origin. Must match StageBackdropView.candyCrop.
let crop = CGRect(x: 223, y: 440, width: 1057, height: 465)
let w = Int(crop.width), h = Int(crop.height)
var rgba = [UInt8](repeating: 0, count: w * h * 4)
rgba.withUnsafeMutableBytes { buffer in
    let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.draw(image.cropping(to: crop)!, in: CGRect(x: 0, y: 0, width: w, height: h))
}
// Rec. 709 weights on the encoded sRGB values: what an feColorMatrix duotone in sRGB computes.
var luma = [UInt8](repeating: 0, count: w * h)
for i in 0..<(w * h) {
    let y = 0.2126 * Double(rgba[i * 4]) + 0.7152 * Double(rgba[i * 4 + 1]) + 0.0722 * Double(rgba[i * 4 + 2])
    luma[i] = UInt8(min(255, y.rounded()))
}
try Data(luma).write(to: URL(fileURLWithPath: args[2]))
print("\(w)x\(h) luma, \(luma.count) bytes -> \(args[2])")
