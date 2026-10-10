import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import T3Client

/// The viewer's JPEG decode (`createPreviewFramePainter`): frames decode off the main thread, and
/// a frame that cannot decode is skipped.
struct FrameDecoderTests {
    static func jpeg(width: Int, height: Int) -> Data {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.6, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    @Test func decodes() {
        let image = FrameDecoder.image(Self.jpeg(width: 64, height: 40))
        #expect(image?.width == 64 && image?.height == 40)
        #expect(FrameDecoder.image(Data("not a jpeg".utf8)) == nil)
    }

    @MainActor
    @Test func deliversNewestFrame() async {
        let decoder = FrameDecoder()
        var sizes: [Int] = []
        decoder.deliver = { sizes.append($0.width) }
        // While the first decodes, later frames replace each other; the last one always lands.
        for w in [10, 20, 30, 40] { decoder.paint(Self.jpeg(width: w, height: 10)) }
        for _ in 0..<100 where sizes.last != 40 { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(sizes.first == 10 && sizes.last == 40 && sizes.count <= 4)
    }
}
