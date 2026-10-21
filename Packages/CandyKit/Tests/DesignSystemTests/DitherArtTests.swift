import AppKit
import Testing
@testable import DesignSystem

/// The Dither theme's art: a picture that matches the background renders as exactly the background, and a bright
/// picture is held to the reach that keeps text readable.
struct DitherArtTests {
    func picture(gray: CGFloat, in dir: URL) throws -> URL {
        let ctx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(red: gray, green: gray, blue: gray, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let url = dir.appending(path: "\(gray).png")
        try NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!.write(to: url)
        return url
    }

    func bytes(_ image: CGImage) -> [UInt8] { [UInt8](image.dataProvider!.data! as Data) }

    @Test func fadesIntoTheBackgroundWithoutStrayDots() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "dither-art-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bg = 10.0 / 255
        let flat = try #require(DitherArt.render(.init(url: try picture(gray: bg, in: dir), width: 80, height: 60, background: [bg, bg, bg], scale: 2)))
        #expect(Set(bytes(flat).enumerated().filter { $0.offset % 4 != 3 }.map(\.element)) == [10])

        let bright = try #require(DitherArt.render(.init(url: try picture(gray: 0.9, in: dir), width: 80, height: 60, background: [bg, bg, bg], scale: 2)))
        let b = bytes(bright), row = bright.bytesPerRow
        let top = (0..<80).map { Int(b[$0 * 4]) }.reduce(0, +) / 80
        let bottom = (0..<80).map { Int(b[59 * row + $0 * 4]) }.reduce(0, +) / 80
        // A gray picture stays gray: every dot is the background or the picture's color at some strength.
        #expect(abs(top - (10 + Int(DitherArt.reach))) <= 8)
        #expect(bottom < top)
        #expect(DitherArt.fade(0.5) == 0.15 && DitherArt.fade(1) < 0.4)
    }
}
