import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import IOSurface
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

    /// The red, green and blue of the buffer's center pixel.
    static func center(_ buffer: CVPixelBuffer) -> [Int] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let row = CVPixelBufferGetHeight(buffer) / 2 * CVPixelBufferGetBytesPerRow(buffer)
        let p = CVPixelBufferGetBaseAddress(buffer)!.advanced(by: row + CVPixelBufferGetWidth(buffer) / 2 * 4).assumingMemoryBound(to: UInt8.self)
        return [Int(p[2]), Int(p[1]), Int(p[0])]
    }

    @Test func decodes() throws {
        let decoder = JPEGSurfaceDecoder()
        // The session follows the frame size; the result is an sRGB-tagged IOSurface a layer shows as is.
        for (w, h) in [(64, 40), (800, 600), (64, 40)] {
            let buffer = try #require(decoder.decode(Self.jpeg(width: w, height: h)))
            #expect(CVPixelBufferGetWidth(buffer) == w && CVPixelBufferGetHeight(buffer) == h)
            #expect(CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA)
            let surface = try #require(CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue())
            #expect(IOSurfaceCopyValue(surface, kIOSurfaceColorSpace) != nil)
            // The same colors as ImageIO's decode.
            let drawn = try #require(JPEGFrame.drawn(Self.jpeg(width: w, height: h)))
            #expect(zip(Self.center(buffer), Self.center(drawn)).allSatisfy { abs($0 - $1) <= 2 })
        }
        #expect(decoder.decode(Data("not a jpeg".utf8)) == nil)
    }

    @MainActor
    @Test func deliversNewestFrame() async {
        let decoder = FrameDecoder(decode: JPEGFrame.drawn)
        var sizes: [Int] = []
        decoder.deliver = { sizes.append(CVPixelBufferGetWidth($0)) }
        // The main thread is busy until the loop ends: frames decoded meanwhile replace each other,
        // and the newest one always lands.
        for w in [10, 20, 30, 40] { decoder.paint(Self.jpeg(width: w, height: 10)) }
        for _ in 0..<3000 where sizes.last != 40 { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(sizes.last == 40 && sizes.count <= 2)
    }
}
